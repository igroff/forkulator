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

#### Things to know

* Commands do have access to the environment that forkulator itself sees, that's a feature
  so don't abuse it.
* forkulator really expects you to return valid JSON, so it will always set the content type of
  the response to 'application/json'
* if your command returns anything other than an exit code of 0, forkulator assumes it has failed.
  In the case of failure a JSON object containing the output of your command will be returned, see
  'Commands' below for an example.

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
          "query": null,
          "body": null,
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
          "url": "/echoStdin",
          "query": null,
          "body": null,
          "headers": {
            "user-agent": "curl/7.37.1",
            "host": "localhost:3000",
            "accept": "*/*"
          },
          "path": "/echoStdin"
        }

Upon successful execution of your command, everything written to stdout during
command execution is streamed back in the response.  Forkulator will always set 
the Content-Type header to 'application/json', however it is up to your command
to output properly formatted JSON.

So what's it look like if your command exits with a non zero exit code?

Given a command called nonzeroExitCodeAndOutput that looks like:

      #! /usr/bin/env bash
      echo "This message was written to stdout"
      echo -n "This message was written to stderr" >&2
      exit 1

Running it should go something like this:

      $ curl http://localhost:3000/nonzeroExitCodeAndOutput --silent | jq .
      {
        "exitCode": 1,
        "signal": "null",
        "output": "This message was written to stderrThis message was written to stdout\n"
      }

*NOTE* The output from a failed command will contain both the contents of the stderr and stdout
io streams resulting from the execution of your command. The contents of these streams are themselves
streamed back in the response and thus come back in *NO PARTICULAR ORDER* so it's up to the caller
to make sense of which stream is which if that's pertinent.

