express     = require 'express'
morgan      = require 'morgan'
connect     = require 'connect'
log         = require 'simplog'
path        = require 'path'
fs          = require 'fs'
Promise     = require 'bluebird'
child_process = require 'child_process'
through = require 'through'

dieInAFire = (message, errorCode=1) ->
  log.error message
  process.exit errorCode

config=
  outputDirectory: process.env.FORKULATOR_TEMP ||
    process.env.TEMP ||
    process.env.TMPDIR || dieInAFire 'I could not find a place to write my output'
  maxConcurrentRequests: process.env.MAX_CONCURRENCY || 5
  commandPath: process.env.COMMAND_PATH || path.join __dirname, "commands"

app = express()
app.use connect()
app.use morgan('combined')

requestCounter = 0
countOfCurrentlyExecutingRequests = 0

createTempFileName = (prefix) ->
  prefix + process.pid + requestCounter++

createTempFilePath = (prefix) ->
  path.join config.outputDirectory, createTempFileName(prefix)

executeThrottled = (req, res) ->
  if config.maxConcurrentRequests is -1 || (countOfCurrentlyExecutingRequests < config.maxConcurrentRequests)
    log.debug 'executing request'
    countOfCurrentlyExecutingRequests++
    handleRequest(req,res).then(() -> countOfCurrentlyExecutingRequests--)
  else
    log.warn "too busy to handle request"
    res.status(503).send(message: "too busy, try again later").end()

app.use((req, res, next) -> executeThrottled(req, res))

promiseToOpen = (stream) ->
  new Promise (resolve, reject) ->
    stream.on 'open', resolve
    stream.on 'error', reject

promiseToEnd = (stream) ->
  new Promise (resolve, reject) ->
    stream.on 'end', resolve
    stream.on 'error', reject

handleRequest = (req,res) ->
  log.debug 'handling request to %s', req.path
  err = null
  pathToHandler = path.join config.commandPath, req.path
  outfilePath = createTempFilePath 'stdout-'
  errfilePath = createTempFilePath 'stderr-'
  outfileStream = fs.createWriteStream outfilePath
  errfileStream = fs.createWriteStream errfilePath

  removeTempFiles = () ->
    fs.unlink outfilePath, (e) -> log.warn(e) if e
    fs.unlink errfilePath, (e) -> log.warn(e) if e
    outfileStream.close()
    errfileStream.close()

  createStreamTransform = () ->
    through((data) ->
      this.emit 'data', data.toString().replace(/\n/g, "\\n"),
      null,
      autoDestroy: false
    )

  Promise.all([promiseToOpen(outfileStream), promiseToOpen(errfileStream)]).then( () ->
    log.debug 'starting process: %s', pathToHandler
    # we're gonna do our best to return json in all cases
    res.type('application/json')
    handler = child_process.spawn(pathToHandler, [],
      stdio: ['pipe', outfileStream, errfileStream])
    handler.on 'error', (e) -> err = e
    handler.stdin.on 'error', (e) ->
      res.status(500).send(message: e)
    handler.on 'close', (exitCode, signal) ->
      if exitCode != 0 || err || signal
        res.status 500
        res.write '{"message":"'
        res.write err + "" if err
        res.write "killed by signal" + signal if signal
        errStream = fs.createReadStream errfilePath
        errStream.on 'error', (e) -> res.write 'error reading stderr from the command ' + e + '\\n'
        outStream = fs.createReadStream outfilePath
        outStream.on 'error', (e) -> res.write 'error reading stdout from the command ' + e + '\\n'
        errStream.pipe(createStreamTransform()).pipe(res, end: false)
        outStream.pipe(createStreamTransform()).pipe(res, end: false)
        promiseToEnd(errStream)
          .then(promiseToEnd(outStream))
          .then( -> res.end('"}'))
      else
        fs.createReadStream(outfilePath).pipe(res)
    # provide our information to the handler on stdin
    handler.stdin.end JSON.stringify(
      url: req.url
      query: req.query
      body: req.body
      headers: req.headers
      path: req.path
    )
  ).catch (e) ->
    log.error(e)
    res.send "something awful happend: " + e

  # when our response is finished (we've sent all we will send)
  # we clean up after ourselves
  new Promise (resolve, reject) ->
    shutDown = () ->
      removeTempFiles()
      resolve()
    res.on 'finish', shutDown
    
listenPort = process.env.PORT || 3000
log.info "starting app " + process.env.APP_NAME
log.info "listening on " + listenPort
log.debug "debug logging enabled"
log.debug config
app.listen listenPort
