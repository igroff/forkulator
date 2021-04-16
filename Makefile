SHELL=/bin/bash
.PHONY: watch lint clean install
COMMAND_PATH=$(PWD)/difftest/commands
APP_NAME?=$(shell basename `pwd`)
MAX_CONCURRENCY?=1
export FORKULATOR_TEMP=$(PWD)/temp
watch:
	@mkdir -p $(FORKULATOR_TEMP)
	COMMAND_PATH=$(COMMAND_PATH) MAX_CONCURRENCY=$(MAX_CONCURRENCY) ./node_modules/.bin/supervisor --watch 'src/,./' --ignore "./test"  -e "litcoffee,coffee,js" --exec make run-server

lint:
	find ./src -name '*.coffee' | xargs ./node_modules/.bin/coffeelint -f ./etc/coffeelint.conf
	find ./src -name '*.js' | xargs ./node_modules/.bin/jshint 

install: node_modules/

node_modules/:
	npm install .

build_output/: node_modules/
	mkdir -p build_output

run-server: build_output/
	exec bash -c "export APP_NAME=${APP_NAME}; test -r ~/.${APP_NAME}.env && . ~/.${APP_NAME}.env ; exec ./node_modules/.bin/coffee server.coffee"

clean:
	rm -rf ./node_modules/
