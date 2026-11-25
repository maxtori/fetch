# evloop, from its source tree (../evloop, built with `make` there), unless
# it is installed: dune finds libraries in OCAMLPATH.
EVLOOP ?= $(abspath ../evloop)
ifneq ($(wildcard $(EVLOOP)/_build/install/default/lib),)
export OCAMLPATH := $(EVLOOP)/_build/install/default/lib$(if $(OCAMLPATH),:$(OCAMLPATH))
endif

# Pass Cargo features to the Rust backend with e.g. `make FETCH_RS_FEATURES=gzip`.
export FETCH_RS_FEATURES

.PHONY: all build release test test-native test-byte test-js test-wasm test-direct promote clean

all: build

build:
	@dune build

release:
	@dune build --profile release

test:
	@dune test

test-native test-byte test-js test-wasm test-direct:
	@dune test test/$(@:test-%=%).t

promote:
	@dune promote

clean:
	@dune clean
