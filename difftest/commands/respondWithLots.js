#! /usr/bin/env node
# vim: ft=javascript

function handleRequest(req, resp){
  console.log("handled!");
  process.exit(0);
}
process.on('message', handleRequest);
