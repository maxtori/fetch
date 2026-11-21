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
