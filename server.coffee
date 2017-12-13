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
  waitForEvent 'finish', stream

returnWhen = (object, theseComplete) ->
  Promise.props(theseComplete).then (completed) -> _.extend(object, completed)

handleRequest = (req,res) ->
  err = null
  # we're gonna do our best to return json in all cases
  res.type('application/json')

  createStreamTransform = () ->
    through (data) ->
      this.emit 'data', data.toString().replace(/\n/g, "\\n"),
      null,
      autoDestroy: false

  createDisposableContext = () ->
    promiseForContext = new Promise (resolve) ->
      context =
        commandFilePath: path.join(config.commandPath, req.path)
        commandPath: req.path
        requestData:
          url: req.url
          query: if _.isEmpty(req.query) then null else req.query
          body: if _.isEmpty(req.body) then null else req.body
          headers: req.headers
          path: req.path
      resolve context
    # during disposal we'll go ahead and close any streams we have lying
    # around.
    promiseForContext.disposer (context) ->
      context.outfileStream.end() if context.outfileStream?.fd
      context.errfileStream.end() if context.errfileStream?.fd
      fs.close(context.stdinfileStream.fd) if context.stdinfileStream?.fd
    

  requestPipeline = (context) ->
    # we start by 'passing in' our context to the promise chain
    Promise.resolve(context)
    .then (context) ->
      # special case for someone trying to hit /, for which there can never
      # be a valid command. We're just gonna throw something that looks like the
      # same error that would be raised in the case of someone calling a more 'valid'
      # but still no existent path
      if context.commandPath is "/"
        err = new Error "Invalid command path: #{context.commandPath}"
        err.code = "ENOENT"
        err.path = context.commandFilePath
        throw err
      context
    # then we're going to open the file that will contain the information
    # we'll be passing to the command via stdin
    .then (context) -> returnWhen(context, stdinfileStream: openForWrite(createTempFilePath 'stdin'))
    # and now we write our data to the stdin file
    .then (context) -> returnWhen(context, stdinWriteStream: writeAndClose(JSON.stringify(context.requestData), context.stdinfileStream))
    # We'll be opening all the files that will comprise the stdio data for use by the
    # command on execution.  Child_process requires that any stream objects it uses
    # already have an FD available when spawn is called so we must wait for those
    # to emit the 'open' event before we can spawn our command process
    .then (context) ->
      whenTheseAreDone =
        stdinfileStream: openForRead(context.stdinWriteStream.path)
        outfileStream: openForWrite(createTempFilePath 'stdout')
        errfileStream: openForWrite(createTempFilePath 'stderr')
      returnWhen(context, whenTheseAreDone)
    # now we fire up the command process as requested, piping in the 
    # request data we have via stdin
    .then (context) ->
      log.debug 'starting process: %s', context.commandFilePath
      commandProcess = child_process.spawn(context.commandFilePath, [], stdio: ['pipe', context.outfileStream, context.errfileStream])
      context.stdinfileStream.pipe commandProcess.stdin
      new Promise (resolve, reject) ->
        # When the process completes and closes all the stdio stream
        # associated with it, we'll get a close, except the stdio streams don't get
        # closed so we do tht all in our context disposer
        commandProcess.on 'close', (exitCode, signal) ->
          context.exitCode = exitCode
          context.signal = signal
          resolve(context)
        commandProcess.on 'error', (e) -> log.error "error from commandProcess: #{util.inspect e}";  reject(e)
        # if the process failes to start, in certain cases, we can get an error
        # writing to stdin
        commandProcess.stdin.on 'error', (e) -> log.error "error from commandProcess.stdin: #{e}";  reject(e)
    .then (context) ->
      # the command execution is complete when we get the 'close' event from commandProcess
      # in the case of error we'll be passing back all the information we have from the close event
      # along with the contents of stderr and stdout generated during command execution
      log.debug "command (#{context.commandFilePath}) completed exit code #{context.exitCode}"
      if context.exitCode != 0 || context.signal
        res.status 500
        res.write "{\"exitCode\":#{context.exitCode},\"signal\":\"#{context.signal}\",\"output\":\""
        errStream = fs.createReadStream context.errfileStream.path
        outStream = fs.createReadStream context.outfileStream.path
        errStream.pipe(createStreamTransform()).pipe(res, end: false)
        outStream.pipe(createStreamTransform()).pipe(res, end: false)
        Promise.join(promiseToEnd(errStream), promiseToEnd(outStream))
          .then(() -> res.write('"}'))
          .then(Promise.resovle)
      else
        # no error, so we're just gonna stream our output generated by
        # the command back on the response
        commandOutputStream = fs.createReadStream(context.outfileStream.path)
        commandOutputStream.pipe(res)
        promiseToEnd(commandOutputStream)
    .catch (e) ->
      # first we check to see if we really just have a request for a non
      # existent command, in which case we'll return a 404
      if e.code is 'ENOENT' and e.path is context.commandFilePath
        log.warn "No command found for #{context.commandPath}"
        res.status(404)
      else
        log.error "something awful happened while running #{context.commandPath}\n#{e}\n#{e.stack}"
        errorObject=
          message: "error"
          error: e.message
        console.log util.inspect(e)
        if req.query["debug"]
          errorObject.stack = e.stack
        res.status(500).send(errorObject)
    .finally () -> res.end()

  Promise.using(createDisposableContext(), requestPipeline)


    
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
log.info config
app.listen listenPort
