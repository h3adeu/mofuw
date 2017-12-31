import asyncnet, asyncdispatch, nativesockets, lib/mofuparser

proc P(value: string, length: int): string =
  return value[0 .. length]
#[
proc makeResp(body: string)

proc makeHeader(name: string, value: string): string {.inline.}=
  var x = ""
  x.add name
  x.add ": "
  x.add value
  x.add "\r\L"
  
  return x]#

var
  TCP_NODELAY {.importc: "TCP_NODELAY", header: "<netinet/tcp.h>".}: cint
  htreq: HttpReq
  hd : array[64, headers]
  hdaddr = hd.addr

  body = "HTTP/1.1 200 OK" & "\r\L" &
         "Connection: keep-alive" & "\r\L" &
         "Content-Length: 11" & "\r\L" &
         "Content-Type: text/plain; charset=utf-8" & "\r\L" & "\r\L" &
         "Hello World"

proc client_cb(client: AsyncFD) {.async.} =
  while true:
    var rc = await client.recv(1024)
    if rc.len == 0:
      closeSocket(client)
      break
    else:
      asyncCheck client.send(body[0].addr, body.len)

proc serve() {.async.} =
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.getFD().setSockOptInt(cint(IPPROTO_TCP), TCP_NODELAY, 1)
  server.bindAddr(Port(8080))
  server.listen()

  let servfd = server.getFD().AsyncFD

  while true:
    let client = await servfd.accept()
    asyncCheck client_cb(client)

asyncCheck serve()
runForever()