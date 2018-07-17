import strtabs, critbits, asyncdispatch
import mofuparser

type
  MofuwHandler* = proc(ctx: MofuwCtx): Future[void] {.gcsafe.}

  VhostTable* = CritBitTree[MofuwHandler]

  ServeCtx* = ref object
    servername*: string
    port*: int
    readBufferSize*, writeBufferSize*: int
    timeout*: int
    poolsize*: int
    handler*, hookrequest*, hookresponse*: MofuwHandler
    vhostTbl*: VhostTable
    when defined ssl:
      sslCtxTbl*: CritBitTree[SslCtx]

  MofuwCtx* = ref object
    fd*: AsyncFD
    mhr*: MPHTTPReq
    mc*: MPChunk
    ip*: string
    buf*, resp*: string
    bufLen*, respLen*: int
    currentBufPos*: int
    bodyStart*: int
    bodyParams*, uriParams*, uriQuerys*: StringTableRef
    vhostTbl*: VhostTable
    when defined ssl:
      isSSL*: bool
      sslCtx*: SslCtx
      sslHandle*: SslPtr

proc newServeCtx*(servername = "mofuw", port: int,
                  handler: MofuwHandler = nil,
                  readBufferSize, writeBufferSize = 4096,
                  timeout = 3 * 1000,
                  poolsize = 128): ServeCtx =
  result = ServeCtx(
    servername: servername,
    port: port,
    handler: handler,
    readBufferSize: readBufferSize,
    writeBufferSize: writeBufferSize,
    timeout: timeout,
    poolsize: poolsize
  )

proc newMofuwCtx*(readSize: int, writeSize: int): MofuwCtx =
  result = MofuwCtx(
    buf: newString(readSize),
    resp: newString(writeSize),
    bufLen: 0,
    respLen: 0,
    currentBufPos: 0,
    mhr: MPHTTPReq()
  )