### Overview

Wouldn't it be nice if you could just make some arbitrary executable run by calling
a properly formed URL. Like, you already have a shell script that tests the health of your
application you just want to make it accessible for your HTTP based monitoring solution. 
Enter `forkulator` the application that just runs your executable files and returns the output.

#### Definitions

* command - A command is an executable file that is to be executed by forkulator. Command files
  must be executable `chmod +x`'d and stored in the location specified by the `COMMAND_PATH`
  environment variable.
* command path - Full path to the directory holding forkulator commands.

#### Configuration (Environment Variables)

* `COMMAND_PATH` - Full path to the directory where your commands are stored
* `FORKULATOR_TEMP` - Full path to a directory where forkulatr can store output of the
   commands it executes. This will happily default to TMP or TMPDIR if those are to
   be found in the environment.  If no value can be found forkulator will log an error
   and refuse to start

#### Commands

Commands are nothing more than executable files stored in the directory specified by 
`COMMAND_PATH`.  When executing a command, forkulator provides some information to the
command. Data provided by forkulator is serialized as JSON and provided to the command
via stdin. 

Here is an example of a command that echoes out stdin, and the response it generates:

First the contents of a command called `echoStdin`:

        #! /usr/bin/env bash
        cat

Next the output from the of invocation of the `echoStdin` command:

        $ curl 'http://localhost:3000/echoStdin' --silent | jq .
        {
          "url": "/echoStdin",
          "query": {},
          "headers": {
            "user-agent": "curl/7.37.1",
            "host": "localhost:3000",
            "accept": "*/*"
          },
          "path": "/echoStdin"
        }

You can even put your commands in a directory within the configured command path:

        $ curl 'http://localhost:3000/subdir/echoStdin' --silent | jq .
        {
          "url": "/subdir/echoStdin",
          "query": {},
          "headers": {
            "user-agent": "curl/7.37.1",
            "host": "localhost:3000",
            "accept": "*/*"
          },
          "path": "/subdir/echoStdin"
        }
