#! /usr/bin/env node
// vim: ft=javascript
//
var util = require('util');
var input = '';

// collect our input data, we're not getting much so this should be no 
// big deal
process.stdin.on('data', function(d){
  input = input + d;
});

process.stdin.on('finish', function(){
  // the data that is coming in on stdin is guaranteed to be valid JSON
  input = JSON.parse(input);
  console.log("received: " + util.inspect(input));
  console.log("handled by " + process.pid + "!");
});
