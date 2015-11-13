express     = require 'express'
morgan      = require 'morgan'
connect     = require 'connect'
log         = require 'simplog'
path        = require 'path'
fs          = require 'fs'
Promise     = require 'bluebird'
through     = require 'through'
_           = require 'lodash'
child_process = require 'child_process'
body_parser   = require 'body-parser'
util          = require 'util'

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
# simply parse all bodies as string so we can pass whatever it
# is to the command
app.use body_parser.text(type: () -> true)
app.use morgan('combined')

# used to uniquely identify requests throughout the lifetime of forkulator
requestCounter = 0
# used to count active requests so throttling, if desired, can be done
countOfCurrentlyExecutingRequests = 0

createTempFileName = (prefix) ->
  prefix + process.pid + requestCounter + ""

createTempFilePath = (prefix) ->
  path.join config.outputDirectory, createTempFileName(prefix)

executeThrottled = (req, res) ->
  requestCounter++
  # if we've not disabled throttling ( set to -1 ) then we see that we're running no
  # more than our maximum allowed concurrent requests
  if config.maxConcurrentRequests is -1 || (countOfCurrentlyExecutingRequests < config.maxConcurrentRequests)
    log.debug 'executing request'
    countOfCurrentlyExecutingRequests++
    handleRequest(req,res).then(() -> countOfCurrentlyExecutingRequests--)
  else
    # deny execution of request, tell caller to try again
    log.warn "too busy to handle request"
    res.status(503).send(message: "too busy, try again later").end()

app.use((req, res, next) -> executeThrottled(req, res))

promiseToEnd = (stream) ->
  new Promise (resolve, reject) ->
    stream.on 'end', () -> resolve(stream)
    stream.on 'error', reject

promiseToOpenForWriting = (path) ->
  stream = fs.createWriteStream(path)
  new Promise (resolve, reject) ->
    stream.on 'open', () -> resolve(stream)
    stream.on 'error', reject

handleRequest = (req,res) ->
  err = null
  pathToHandler = path.join config.commandPath, req.path

  createStreamTransform = () ->
    through (data) ->
      this.emit 'data', data.toString().replace(/\n/g, "\\n"),
      null,
      autoDestroy: false

  stdinString = JSON.stringify
    url: req.url
    query: if _.isEmpty(req.query) then null else req.query
    body: if _.isEmpty(req.body) then null else req.body
    headers: req.headers
    path: req.path

  Promise.all [promiseToOpenForWriting(createTempFilePath 'stdout-'), promiseToOpenForWriting(createTempFilePath 'stderr-')]
  .spread (outfileStream, errfileStream) ->
    log.debug 'starting process: %s', pathToHandler
    # we're gonna do our best to return json in all cases
    res.type('application/json')
    handler = child_process.spawn(pathToHandler, [], stdio: ['pipe', outfileStream, errfileStream])
    handler.on 'error', (e) -> err = e
    handler.stdin.on 'error', (e) ->
      log.error "stdin error #{e}"
      res.status(500).send(message: e)
    # feed our data to the handler
    handler.stdin.end stdinString
    handler.on 'close', (exitCode, signal) ->
      #handler.stdin.removeAllListeners 'error'
      log.debug "command completed exit code #{exitCode}"
      if exitCode != 0 || err || signal
        res.status 500
        res.write '{"message":"'
        res.write err + "" if err
        res.write "killed by signal" + signal if signal
        errStream = fs.createReadStream errfileStream.path
        errStream.on 'error', (e) -> res.write 'error reading stderr from the command ' + e + '\\n'
        outStream = fs.createReadStream outfileStream.path
        outStream.on 'error', (e) -> res.write 'error reading stdout from the command ' + e + '\\n'
        errStream.pipe(createStreamTransform()).pipe(res, end: false)
        outStream.pipe(createStreamTransform()).pipe(res, end: false)
        promiseToEnd(errStream)
          .then(promiseToEnd(outStream))
          .then( -> res.end('"}'))
      else
        fs.createReadStream(outfileStream.path).pipe(res)
    # when our response is finished (we've sent all we will send)
    # we clean up after ourselves
    new Promise (resolve, reject) ->
      res.on 'finish', () -> resolve([errfileStream.path, outfileStream.path])
  .spread (errfilePath, outfilePath) ->
    fs.unlink(outfilePath, (e) -> log.warn(e) if e)
    fs.unlink(errfilePath, (e) -> log.warn(e) if e)
  .catch (e) ->
    log.error "something awful happened #{e}\n#{e.stack}"
    res.end "something awful happend: " + e
    
listenPort = process.env.PORT || 3000
log.info "starting app " + process.env.APP_NAME
log.info "listening on " + listenPort
log.debug "debug logging enabled"
log.debug config
app.listen listenPort
