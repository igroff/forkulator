express     = require 'express'
morgan      = require 'morgan'
cookieParser = require 'cookie-parser'
connect     = require 'connect'
log         = require 'simplog'
path        = require 'path'
fs          = require 'fs'
Promise     = require 'bluebird'
child_process = require 'child_process'

config=
  outputDirectory: process.env.FORK_OUTPUT ||
    process.env.TEMP ||
    process.env.TMPDIR
  maxConcurrentRequests: 1

app = express()
app.use connect()
app.use morgan('combined')
app.use cookieParser()

requestCounter = 0
countOfCurrentlyExecutingRequests = 0

createTempFileName = (prefix) ->
  prefix + process.pid + requestCounter++

executeThrottled = (req, res) ->
  if(countOfCurrentlyExecutingRequests < config.maxConcurrentRequests)
    log.debug 'executing request'
    countOfCurrentlyExecutingRequests++
    handleRequest(req,res).then(() -> countOfCurrentlyExecutingRequests--)
  else
    log.debug 'queueing request'
    delayed = () -> executeThrottled(req, res)
    setTimeout(delayed, 1)

app.use((req, res, next) -> executeThrottled(req, res))

handleRequest = (req,res) ->
  log.debug 'handling request to %s', req.path
  err = null
  captureError = (e) -> err = e
  pathToHandler = path.join __dirname, "commands", req.path
  outfilePath = path.join config.outputDirectory, createTempFileName('testsdout')
  errfilePath = path.join config.outputDirectory, createTempFileName('testsderr')
  outfileStream = fs.createWriteStream outfilePath
  errfileStream = fs.createWriteStream errfilePath
  handler = null
  removeTempFiles = () ->
    fs.unlink outfilePath, (e) -> log.warn(e) if e
    fs.unlink errfilePath, (e) -> log.warn(e) if e
    outfileStream.close()
    errfileStream.close()
  outfileStreamOpened = new Promise (resolve, reject) ->
    outfileStream.on 'open', resolve
  errfileStreamOpened = new Promise (resolve, reject) ->
    errfileStream.on 'open', resolve
  Promise.all([outfileStreamOpened, errfileStreamOpened]).then( () ->
    log.debug 'starting process: %s', pathToHandler
    handler = child_process.spawn(pathToHandler, [],
      stdio: ['pipe', outfileStream, errfileStream])
    handler.on 'error', captureError
    handler.stdin.on 'error', (e) ->
      res.type('application/json').status(500).send(message: e)
    handler.on 'close', (exitCode, signal) ->
      if exitCode != 0 || err || signal
        res.status 500
        res.write '{"message":"'
        res.write err + "" if err
        res.write "killed by signal" + signal if signal
        errStream = fs.createReadStream errfilePath
        errStream.on 'end', -> res.end('"}')
        errStream.on 'error', (e) -> res.write('there was trouble reading error output from the process ' + e)
        errStream.pipe res, end:false
      else
        res.type 'application/json'
        fs.createReadStream(outfilePath).pipe(res)
    handler.stdin.end(JSON.stringify(
      url: req.url,
      query: req.query,
      body: req.body,
      headers: req.headers,
      path: req.path
    ))
  ).catch (e) -> log.error(e)
  new Promise (resolve, reject) ->
    shutDown = () ->
      removeTempFiles()
      resolve()
    res.on 'finish', shutDown
    
listenPort = process.env.PORT || 3000
log.info "starting app " + process.env.APP_NAME
log.info "listening on " + listenPort
log.debug "debug logging enabled"
app.listen listenPort
