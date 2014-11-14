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
  maxConcurrentRequests: process.env.MAX_CONCURRENCY || 5

app = express()
app.use connect()
app.use morgan('combined')
app.use cookieParser()

requestCounter = 0
countOfCurrentlyExecutingRequests = 0

createTempFileName = (prefix) ->
  prefix + process.pid + requestCounter++

createTempFilePath = (prefix) ->
  path.join config.outputDirectory, createTempFileName(prefix)

executeThrottled = (req, res) ->
  if(countOfCurrentlyExecutingRequests < config.maxConcurrentRequests)
    log.debug 'executing request'
    countOfCurrentlyExecutingRequests++
    handleRequest(req,res).then(() -> countOfCurrentlyExecutingRequests--)
  else
    log.debug 'queueing request'
    handleLater = () -> executeThrottled(req, res)
    setTimeout handleLater, 0

app.use((req, res, next) -> executeThrottled(req, res))

promiseYouWillOpen = (stream) ->
  new Promise (resolve, reject) -> stream.on('open', resolve)

handleRequest = (req,res) ->
  log.debug 'handling request to %s', req.path
  err = null
  pathToHandler = path.join __dirname, "commands", req.path
  outfilePath = createTempFilePath 'testsdout'
  errfilePath = createTempFilePath 'testsderr'
  outfileStream = fs.createWriteStream outfilePath
  errfileStream = fs.createWriteStream errfilePath

  removeTempFiles = () ->
    fs.unlink outfilePath, (e) -> log.warn(e) if e
    fs.unlink errfilePath, (e) -> log.warn(e) if e
    outfileStream.close()
    errfileStream.close()

  
  Promise.all([promiseYouWillOpen(outfileStream), promiseYouWillOpen(errfileStream)]).then( () ->
    log.debug 'starting process: %s', pathToHandler
    handler = child_process.spawn(pathToHandler, [],
      stdio: ['pipe', outfileStream, errfileStream])
    handler.on 'error', (e) -> err = e
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
      url: req.url, query: req.query, body: req.body, headers: req.headers,
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
log.debug config
app.listen listenPort
