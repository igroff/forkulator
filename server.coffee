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
stream        = require 'stream'

dieInAFire = (message, errorCode=1) ->
  log.error message
  process.exit errorCode

config=
  outputDirectory: process.env.FORKULATOR_TEMP ||
    process.env.TEMP ||
    process.env.TMPDIR || dieInAFire 'I could not find a place to write my output'
  maxConcurrentRequests: process.env.MAX_CONCURRENCY || 5
  commandPath: process.env.COMMAND_PATH || path.join __dirname, "commands"


# used to uniquely identify requests throughout the lifetime of forkulator
requestCounter = 0
# used to count active requests so throttling, if desired, can be done
countOfCurrentlyExecutingRequests = 0

createTempFileName = (suffix) ->
  process.pid + requestCounter + "-" + suffix

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


waitForEvent = (resolveEvent, emitter, rejectEvent='error') ->
  new Promise (resolve, reject) ->
    emitter.on resolveEvent, () -> resolve(emitter)
    emitter.on(rejectEvent, reject) if rejectEvent

promiseToEnd = (stream) ->
  waitForEvent 'end', stream

openForWrite = (path) ->
  waitForEvent 'open', fs.createWriteStream(path)

openForRead = (path) ->
  waitForEvent 'open', fs.createReadStream(path)

writeAndClose = (data, stream) ->
  stream.end data
  waitForEvent 'close', stream

returnWhen = (object, theseComplete) ->
  Promise.props(_.extend(object, theseComplete))

handleRequest = (req,res) ->
  err = null
  # we're gonna do our best to return json in all cases
  res.type('application/json')

  createStreamTransform = () ->
    through (data) ->
      this.emit 'data', data.toString().replace(/\n/g, "\\n"),
      null,
      autoDestroy: false

  context =
    commandFilePath: path.join(config.commandPath, req.path)
    errorMessage: ''

  Promise.resolve(context)
  .then (context) -> returnWhen(context,
    requestData:
      url: req.url
      query: if _.isEmpty(req.query) then null else req.query
      body: if _.isEmpty(req.body) then null else req.body
      headers: req.headers
      path: req.path
    )
  .then (context) -> returnWhen(context, stdinfileStream: openForWrite(createTempFilePath 'stdin'))
  .then (context) -> returnWhen(context, stdinWriteStream: writeAndClose(JSON.stringify(context.requestData), context.stdinfileStream))
  .then (c) ->
    whenTheseAreDone =
      stdinfileStream: openForRead(c.stdinWriteStream.path)
      outfileStream: openForWrite(createTempFilePath 'stdout')
      errfileStream: openForWrite(createTempFilePath 'stderr')
    returnWhen(c, whenTheseAreDone)
  .then (context) ->
    log.debug 'starting process: %s', context.commandFilePath
    commandProcess = child_process.spawn(context.commandFilePath, [], stdio: ['pipe', context.outfileStream, context.errfileStream])
    context.stdinfileStream.pipe commandProcess.stdin
    new Promise (resolve, reject) ->
      # When the process completes and closes all the stdio stream
      # associated with it, we'll get a close
      commandProcess.on 'close', (exitCode, signal) ->
        context.exitCode = exitCode
        context.signal = signal
        resolve(context)
      commandProcess.on 'error', reject
      # if the process failes to start, in certain cases, we can get an error
      # writing to stdin
      commandProcess.stdin.on 'error', reject
  .then (context) ->
    log.debug "command (#{context.commandFilePath}) completed exit code #{context.exitCode}"
    if context.exitCode != 0 || context.signal
      res.write "{\"exitCode\":#{context.exitCode},\"signal\":\"#{context.signal}\",\"output\":\""
      errStream = fs.createReadStream context.errfileStream.path
      outStream = fs.createReadStream context.outfileStream.path
      errStream.pipe(createStreamTransform()).pipe(res, end: false)
      outStream.pipe(createStreamTransform()).pipe(res, end: false)
      Promise.join(promiseToEnd(errStream), promiseToEnd(outStream))
        .then(() -> res.write('"}'))
        .then(Promise.resovle)
    else
      commandOutputStream = fs.createReadStream(context.outfileStream.path)
      commandOutputStream.pipe(res)
      promiseToEnd(commandOutputStream)
  .catch (e) ->
    log.error "something awful happened #{e}\n#{e.stack}"
    res.write "something awful happend: " + e
  .error (e) ->
    log.error "something awful happened #{e}\n#{e.stack}"
    res.write "something awful happend: " + e
  .finally () -> res.end()
    
app = express()
app.use connect()
# simply parse all bodies as string so we can pass whatever it
# is to the command, we treat the in and out of the command as 
# opaque simply feeding in what we get
app.use body_parser.text(type: () -> true)
app.use morgan('combined')
app.use((req, res, next) -> executeThrottled(req, res))

listenPort = process.env.PORT || 3000
log.info "starting app " + process.env.APP_NAME
log.info "listening on " + listenPort
log.debug "debug logging enabled"
log.debug config
app.listen listenPort
