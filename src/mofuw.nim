import
  net,
  hashes,
  macros,
  osproc,
  tables,
  strtabs,
  strutils,
  threadpool,
  asyncdispatch,
  nativesockets

from httpcore import HttpHeaders

when defined(windows):
  import asyncnet
  from winlean import TCP_NODELAY
else:
  from posix import TCP_NODELAY, EAGAIN, EWOULDBLOCK

when defined(linux):
  from posix import Pid
  const TCP_FASTOPEN = 23.cint

from os import osLastError

import
  mofuparser,
  mofuhttputils,
  mofuw/jesterPatterns,
  mofuw/jesterUtils

export
  strtabs,
  mofuhttputils,
  asyncdispatch,
  jesterPatterns

type
  mofuwReq* = ref object
    mhr: MPHTTPReq
    buf*: string
    bodyStart: int
    bParams, params*: StringTableRef
    # this is for big request
    # TODO
    tmp*: cstring

  mofuwRes* = ref object
    fd: AsyncFD

  Callback = proc(req: mofuwReq, res: mofuwRes): Future[void]

const
  kByte = 1024
  mByte = 1024 * kByte

  defaultBufferSize = 8 * kByte
  defaultMaxBodySize {.intdefine.} = 10 * mByte
  bufSize {.intdefine.} = 512

var
  cacheTables {.threadvar.}: TableRef[string, string]
  callback    {.threadvar.}: Callback
  maxBodySize {.threadvar.}: int
  bufferSize  {.threadvar, deprecated.}: int

proc countCPUs(): int =
  when defined(linux):
    const
      schedh = "#define _GNU_SOURCE\n#include <sched.h>"
    type CpuSet {.importc: "cpu_set_t", header: schedh.} = object
      when defined(linux) and defined(amd64):
        abi: array[1024 div (8 * sizeof(culong)), culong]
    var set: CpuSet
    proc sched_getAffinity(pid: Pid, cpusetsize: int, mask: var CpuSet): cint {.
      importc: "sched_getaffinity", header: schedh.}
    proc cpusetCount(s: var CpuSet): int {. importc: "CPU_COUNT", header: schedh.}
    if sched_getAffinity(0, sizeof(CpuSet), set) == 0.cint:
      return cpusetCount(set)
    else:
      return countProcessors()
  else:
    return countProcessors()

proc newServerSocket(port: int = 8080, backlog: int = 128): SocketHandle =
  let server = newSocket()

  server.setSockOpt(OptReuseAddr, true)

  server.setSockOpt(OptReusePort, true)

  server.getFD().setSockOptInt(cint(IPPROTO_TCP), TCP_NODELAY, 1)

  when defined(linux):
    server.getFD().setSockOptInt(cint(IPPROTO_TCP), TCP_FASTOPEN, 256)

  server.getFd.setBlocking(false)

  server.bindAddr(Port(port))

  server.listen(backlog.cint)

  return server.getFd()

proc hash(str: string): Hash =
  var h = 0
  
  for v in str:
    h = h !& v.int

  result = !$h

proc getMethod*(req: mofuwReq): string {.inline.} =
  result = getMethod(req.mhr)

proc getPath*(req: mofuwReq): string {.inline.} =
  result = getPath(req.mhr)

proc getCookie*(req: mofuwReq): string {.inline.} =
  result = getHeader(req.mhr, "Cookie")

proc getHeader*(req: mofuwReq, name: string): string {.inline.} =
  result = getHeader(req.mhr, name)

proc toHttpHeaders*(req: mofuwReq): HttpHeaders {.inline.} =
  result = req.mhr.toHttpHeaders()

proc bodyParse*(req: mofuwReq): StringTableRef =
  req.bodyParse

proc body*(req: mofuwReq, key: string = nil): string =
  if key.isNil: return $req.buf[req.bodyStart .. ^1]
  if req.bParams.isNil: req.bParams = req.body.bodyParse
  req.bParams.getOrDefault(key)

proc mofuwSend*(res: mofuwRes, body: string) {.async.} =
  var buf: string
  shallowcopy(buf, body)

  # try send because raise exception.
  # buffer not protect, but
  # mofuwReq have buffer, so this is safe.(?)
  let fut = send(res.fd, addr(buf[0]), buf.len)
  yield fut
  if fut.failed:
    try:
      closeSocket(res.fd)
    except:
      # TODO send error logging
      discard

proc notFound*(res: mofuwRes) {.async.} =
  await mofuwSend(res, notFound())

proc cacheResp*(res: mofuwRes, path, status, mime, body: string) {.async.} =
  if cacheTables.hasKey(path):
    asyncCheck res.mofuwSend(cacheTables[path])
    return
  else:
    let buf = makeResp(
      status,
      mime,
      body
    )

    asyncCheck res.mofuwSend(buf)

    cacheTables[path] = buf

    proc cacheCB(fd: AsyncFD): bool =
      cacheTables[path] = makeResp(
        status,
        mime,
        body
      )
      result = false

    addTimer(1000, false, cacheCB)

proc handler(fd: AsyncFD) {.async.} =
  when defined(windows):
    block handler:
      var
        request = mofuwReq(buf: "", mhr: MPHTTPReq())
        response = mofuwRes(fd: fd)

      while true:
        # on Windows, need linecheck.
        # because Windows is shitty.
        # TODO recvLine is deprecated.
        let recv = await recvLine(fd)
        if recv == "":
          try:
            closeSocket(fd)
          except:
            discard
          finally:
            break
        else:
          # if request is big, return bodyTooLarge
          if recv.len > bufSize:
            await response.mofuwSend(bodyTooLarge())
            closeSocket(fd)
            break handler
          request.buf.add(recv)
          if not(recv == "\c\L"):
            # add \c\L
            # because not added \c\L request.buf.add(recv)
            request.buf.add("\c\L")
            continue

          let r = mpParseRequest(addr request.buf[0], request.mhr)

          if r <= 0:
            await response.mofuwSend(notFound())
            closeSocket(fd)
            break handler
          
          let cl = request.getHeader("Content-Length")
          # if have Content-Length, try recv body.
          # TODO recv body timeout
          if not(cl == ""):
            if cl.parseInt > maxBodySize:
              await response.mofuwSend(bodyTooLarge())
              closeSocket(fd)
              break handler
            let r = await recv(fd, cl.parseInt)
            request.buf.add(r)

          request.bodyStart = r
          
          try:
            await callback(request, response)
          except:
            # TODO error check.
            discard

          # for pipeline ?
          var
            isGETorHEAD = (request.getMethod == "GET") or (request.getMethod == "HEAD")
            remainingBufferSize = request.buf.len - request.bodyStart - 1

          while true:
            if unlikely(isGETorHEAD and (remainingBufferSize > 0)):
              request.buf.delete(0, request.bodyStart)
              let r = mpParseRequest(addr request.buf[0], request.mhr)

              if r <= 0:
                await response.mofuwSend(notFound())
                closeSocket(fd)
                break handler

              request.bodyStart = r
              try:
                await callback(request, response)
              except:
                # erro check.
                discard
              remainingBufferSize = request.buf.len - request.bodyStart - 1
            else:
              break

  else:
    var
      r: int
      buf: array[bufSize, char]

    block handler:
      while true:
        # using our buffer
        r = await recvInto(fd, addr buf[0], bufSize)
        if r == 0:
          try:
            closeSocket(fd)
          except:
            discard
          finally:
            break 
        else:
          var
            request = mofuwReq(buf: "", mhr: MPHTTPReq())
            response = mofuwRes(fd: fd)
  
          let ol = request.buf.len
          request.buf.setLen(ol+r)
          for i in 0 ..< r: request.buf[ol+i] = buf[i]
  
          if request.buf.len > maxBodySize:
            await response.mofuwSend(bodyTooLarge())
            closeSocket(fd)
            break handler

          if r == bufSize:
            while true:
              let r = fd.SocketHandle.recv(addr buf[0], bufSize, 0)
              case r
              of 0:
                await response.mofuwSend(bodyTooLarge())
                closeSocket(fd)
                break handler
              of -1:
                if osLastError().int in {EAGAIN, EWOULDBLOCK}: break
                await response.mofuwSend(bodyTooLarge())
                closeSocket(fd)
                break handler
              else:
                let ol = request.buf.len
                request.buf.setLen(ol+r)
                for i in 0 ..< r: request.buf[ol+i] = buf[i]
  
          let r = mpParseRequest(addr request.buf[0], request.mhr)

          if r <= 0:
            await response.mofuwSend(notFound())
            closeSocket(fd)
            break handler
        
          request.bodyStart = r
        
          try:
            await callback(request, response)
          except:
            # erro check.
            discard

          # for pipeline ?
          var
            isGETorHEAD = (request.getMethod == "GET") or (request.getMethod == "HEAD")
            remainingBufferSize = request.buf.len - request.bodyStart - 1

          while true:
            if unlikely(isGETorHEAD and (remainingBufferSize > 0)):
              request.buf.delete(0, request.bodyStart)
              let r = mpParseRequest(addr request.buf[0], request.mhr)

              if r <= 0:
                await response.mofuwSend(notFound())
                closeSocket(fd)
                break handler

              request.bodyStart = r
              try:
                await callback(request, response)
              except:
                # erro check.
                discard
              remainingBufferSize = request.buf.len - request.bodyStart - 1
            else:
              break

proc updateTime(fd: AsyncFD): bool =
  updateServerTime()
  return false

proc mofuwInit(port, backlog, bufSize, mBodySize: int;
               tables: TableRef[string, string]) {.async.} =
  let server = newServerSocket(port, backlog).AsyncFD
  maxBodySize = mBodySize
  cacheTables = tables
  register(server)
  updateServerTime()
  addTimer(1000, false, updateTime)
  while true:
    try:
      let client = await accept(server)
      client.SocketHandle.setBlocking(false)
      # handler error check.
      asyncCheck handler(client)
    except:
      # TODO async sleep.
      # await sleepAsync(10)
      continue

proc run(port, backlog, bufSize, maxBodySize: int;
         cb: Callback, tables: TableRef[string, string]) {.thread.} =

  callback = cb
  waitFor mofuwInit(port, backlog, bufSize, maxBodySize, tables)

proc defaultBacklog(): int =
  when defined(linux):
    proc fscanf(c: File, frmt: cstring): cint
      {.varargs, importc, header: "<stdio.h>".}

    var
      backlog: int = SOMAXCONN
      f: File
      tmp: int

    if f.open("/proc/sys/net/core/somaxconn"): # See `man 2 listen`.
      if fscanf(f, "%d", tmp.addr) == cint(1):
        backlog = tmp
      f.close
    return backlog
  else:
    return SOMAXCONN

proc mofuwRun*(cb: Callback,
               port: int = 8080,
               backlog: int = defaultBacklog(),
               bufSize: int = defaultBufferSize,
               maxBodySize: int = defaultMaxBodySize) =

  if cb == nil:
    raise newException(Exception, "callback is nil.")

  cacheTables = newTable[string, string]()

  for i in 0 ..< countCPUs():
    spawn run(port, backlog, bufSize, maxBodySize, cb, cacheTables)

  sync()

template mofuwResp*(status, mime, body: string): typed =
  asyncCheck res.mofuwSend(makeResp(
    status,
    mime,
    body
  ))

macro routes*(body: untyped): typed =
  result = newStmtList()

  var
    methodCase = newNimNode(nnkCaseStmt)
    methodTables = initTable[string, NimNode]()
    caseTables = initTable[string, NimNode]()

  methodCase.add(
    newCall(
      "getMethod",
      ident("req")
    )
  )

  for i in 0 ..< body.len:
    case body[i].kind
    of nnkCommand:
      let
        cmdName = body[i][0].ident.`$`.normalize.toUpperAscii()
        cmdPath = $body[i][1]

      if not methodTables.hasKey(cmdName):
        methodTables[cmdName] = newNimNode(nnkOfBranch)

        methodTables[cmdName].add(newLit(cmdName))

      if not caseTables.hasKey(cmdName):
        caseTables[cmdName] = newStmtList()

        caseTables[cmdName].add(
          newNimNode(nnkVarSection).add(
            newNimNode(nnkIdentDefs).add(
              ident("pat"), 
              ident("Pattern"),
              newNimNode(nnkEmpty)
            ),
            newNimNode(nnkIdentDefs).add(
              ident("re"), 
              newNimNode(nnkTupleTy).add(
                newNimNode(nnkIdentDefs).add(
                  ident("matched"), 
                  ident("bool"),
                  newNimNode(nnkEmpty)
                ),
                newNimNode(nnkIdentDefs).add(
                  ident("params"), 
                  ident("StringTableRef"),
                  newNimNode(nnkEmpty)
                )
              ),
              newNimNode(nnkEmpty)
            ),
            newNimNode(nnkIdentDefs).add(
              ident("path"), 
              newNimNode(nnkEmpty),
              newCall(
                "getPath",
                ident("req")
              )
            )
          ),
          newBlockStmt(
            ident("router"),
            newStmtList()
          )
        )

      caseTables[cmdName].findChild(it.kind == nnkBlockStmt)[1].add(
        newAssignment(
          ident("pat"),
          newCall(
            ident("parsePattern"),
            newStrLitNode(cmdPath)
          )
        )
      )

      caseTables[cmdName].findChild(it.kind == nnkBlockStmt)[1].add(
        newAssignment(
          ident("re"),
          newCall(
            ident("match"),
            ident("pat"),
            ident("path")
          )
        )
      )

      caseTables[cmdName].findChild(it.kind == nnkBlockStmt)[1].add(
        newAssignment(
          newDotExpr(
            ident("req"),
            ident("params")
          ),
          newDotExpr(
            ident("re"),
            ident("params")
          )
        )
      )

      caseTables[cmdName].findChild(it.kind == nnkBlockStmt)[1].add(
        newIfStmt(
          (newDotExpr(
            ident("re"),
            ident("matched")
          ),
          body[i][2].add(
            parseStmt("break router")
          ))
        )
      )
    else:
      discard

  var
    nFound = newStmtList()
    elseMethod = newNimNode(nnkElse)

  nFound.add(
    newNimNode(nnkCommand).add(
      newIdentNode("asyncCheck"),
      newCall(
        "notFound",
        ident("res")
      )
    )
  )

  elseMethod.add(
    newStmtList(
      newNimNode(nnkCommand).add(
        newIdentNode("asyncCheck"),
        newCall(
          "notFound",
          ident("res")
        )
      )
    )
  )

  for k, v in caseTables.pairs:
    v.findChild(it.kind == nnkBlockStmt)[1].add(nFound)
    methodTables[k].add(v)

  for k, v in methodTables.pairs:
    methodCase.add(v)

  methodCase.add(elseMethod)

  result.add(methodCase)
