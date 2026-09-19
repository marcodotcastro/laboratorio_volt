SHELL := /bin/bash

.PHONY: issue issue-destroy destroy up down restart reset

# Keep the CLI surface deliberately small; product component adapters are
# internal implementation details and are not operator-facing targets.
ISSUE ?= $(word 2,$(MAKECMDGOALS))
TYPE ?= improvement
export ISSUE
export TYPE

# GNU Make treats `make issue 1987` as two goals. Keep the second goal from
# producing a Make error; scripts/issue.sh remains responsible for validating
# it as an issue identifier.
ifneq ($(filter issue issue-destroy destroy,$(MAKECMDGOALS)),)
.DEFAULT:
	@:
endif

issue:
	@./bin/vdd issue create $(ISSUE) --type $(TYPE)

issue-destroy:
	@./bin/vdd issue destroy $(ISSUE)

destroy:
	@./bin/vdd issue destroy $(ISSUE)

up:
	@./bin/vdd up

down:
	@./bin/vdd down

restart:
	@./bin/vdd restart

reset:
	@./bin/vdd reset
