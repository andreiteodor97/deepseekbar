# DeepSeekBar — build, test, package.
#
#   make            compile the app
#   make run        compile, install to ~/Applications, and launch
#   make test       run the rate/schedule test suite
#   make screenshots  regenerate the images in docs/
#   make release    build a distributable zip + dmg with checksums
#   make clean      remove build products

SHELL := /bin/bash
VERSION := $(shell cat VERSION | tr -d '[:space:]')
DIST := dist

.PHONY: all build run test release clean check screenshots version

all: build

build:
	@./build.sh

run:
	@./build.sh --install

test:
	@./test.sh

# Verifies the tree is in a shippable state before tagging.
check: test
	@shellcheck --version >/dev/null 2>&1 && shellcheck build.sh test.sh tools/*.sh 2>/dev/null || true
	@python3 -m py_compile tools/trace_whale.py && echo "python tools compile"
	@echo "==> check passed"

screenshots:
	@./tools/screenshot.sh docs

release: test
	@./tools/package.sh

clean:
	@rm -rf build $(DIST)
	@echo "cleaned"

version:
	@echo $(VERSION)
