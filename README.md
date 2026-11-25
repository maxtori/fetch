# fetch: a tiny async HTTP client for OCaml (same code on native, bytecode, JS and Wasm)

Libraries:

- `fetch`: callback API (`Fetch.req`, `Fetch.req_bs`, streaming responses
  with `Fetch.req_stream` / `read` / `read_bs` / `close`, timers with
  `Fetch.after`, or `Fetch.timer` / `Fetch.cancel`, optional `Fetch.run`).
  Uses no effects: OCaml ≥ 4.12.
- `fetch.direct`: direct style on top of it, using OCaml 5 effect handlers
  (`Fetch_direct.spawn`, `req`, `req_bs`, `sleep`, `fork`, `all`, `both`,
  `race` with cancellation of the losers, `Promise`, `suspend`). The fibers
  are evloop's (`Evloop_direct`), shared with other libraries such as
  `idb.direct`: one fiber can wait for both. Built on OCaml ≥ 5 only.
- `fetch.lwt` / `fetch.eio` (native): requests driven by a Lwt or Eio event
  loop, for programs whose main loop never returns (servers). Built when lwt /
  eio are installed (any lwt; eio ≥ 0.2, which itself needs OCaml 5).
- `fetch.ez_api_lwt` / `fetch.ez_api_eio` (native): engines for
  [ez_api](https://github.com/OCamlPro/ez_api)'s clients `ez_api.req_lwt`
  and `ez_api.req_eio`. Built when ez_api (≥ 3.0.0) is installed.

```ocaml
(* callbacks *)
let () = Fetch.req "https://example.com" (function
  | Ok r -> Printf.printf "%d\n" r.status
  | Error e -> prerr_endline e)

(* direct style *)
let () = Fetch_direct.spawn @@ fun () ->
  match Fetch_direct.req "https://example.com" with
  | Ok r -> Printf.printf "%d\n" r.status
  | Error e -> prerr_endline e
```

You don't need to start the event loop. As in JS, it runs once the main
program is done.

Responses are `{ status; headers; body }`:

- `headers : Fetch.Headers.t`, parsed only when you look at them
  (`Headers.get r.headers "content-type"`, `get_all`, `to_list`);
- `body : string` with `req` / `Fetch_direct.req`, or a char
  Bigarray (`Fetch.bigstring`, same type as `Bigstringaf.t`) with
  `req_bs` / `Fetch_direct.req_bs`. The Bigarray
  variant delivers the body without copying: on native it is the buffer Rust
  read it into, on JS it wraps the response's `ArrayBuffer`.

To process a body as it arrives (large bodies, server-sent events, logs,
responses that never end), use `req_stream`: its callback runs once the
headers have arrived, and the body is then read one chunk at a time.

```ocaml
let () = Fetch_direct.spawn @@ fun () ->
  match Fetch_direct.req_stream "https://example.com/events" with
  | Error e -> prerr_endline e
  | Ok { Fetch.body = s; _ } ->
    let rec loop () =
      match Fetch_direct.read ~timeout:30. s with  (* at most 30 s per chunk *)
      | Ok (Some chunk) -> print_string chunk; loop ()
      | Ok None -> ()                               (* end of the body *)
      | Error e -> prerr_endline e                  (* "timeout", ... *)
    in
    loop ()
```

`?timeout` on `req_stream` bounds the wait for the headers, and on `read`
the wait for the next chunk; nothing is read while no read is pending.
Read a stream to its end, or `Fetch.close` it, to release its connection.
Chunks are what the network delivered (their size varies), as strings
(`read`) or Bigarrays (`read_bs`). Same API in `fetch.direct`, `fetch.lwt`
and `fetch.eio`.

```
src/fetch.ml(i)              callback API + the primitives
src/fetch_runtime.js         js_of_ocaml primitives -> host `fetch`, JS event loop schedules
src/fetch_runtime.wat        wasm_of_ocaml primitives (OCaml <-> JS value conversion)
src/fetch_runtime_wasm.js      ... and their JS helper, which calls the host `fetch`
src/fetch_stubs.c            C glue: OCaml values <-> plain C data
src/rust/                    Rust primitives -> reqwest + rustls (ring) on tokio
src/localize.sh              keeps only the C entry points of the Rust library global,
                             so that a program can link other Rust libraries (idb)
src/direct/fetch_direct.ml   effect handler, fibers, promises
src/lwt/, src/eio/           fetch.lwt and fetch.eio
src/lwt/ez_api/, src/eio/ez_api/  ez_api engines (fetch.ez_api_lwt, fetch.ez_api_eio)
example/callbacks.ml         uses fetch only
example/direct.ml            uses fetch.direct
example/daemon.ml            polls URLs every N seconds (fetch, Fetch.after)
test/                        tests (`dune test`, see "Tests" below)
```

The primitives (`caml_fetch_request`, `caml_fetch_request_bigstring`,
`caml_fetch_dispatch`, `caml_fetch_run_local_until`, ...) are declared once as `external`s and implemented three
times. Dune picks the C/Rust ones for native/bytecode, the JS ones for
js_of_ocaml and the WAT ones for wasm_of_ocaml, so there is no virtual
library or functor.

The event loop is [evloop](../evloop)'s: fetch registers as one of its
sources, so a program using other libraries built the same way (idb, for
instance) has one loop for all of them: one at-exit loop, one `run`, one
fd for another event loop to watch.

Native scheduling has two modes. In both, OCaml callbacks run on the OCaml
thread only. With `fetch.direct`, a callback resumes the suspended
continuation.

- **Local mode** (default): tokio runs on the OCaml thread, when the loop has
  nothing else to do, and a finished request's task calls its callback
  directly. No threads, no hand-off: the fastest mode, for programs that let
  the loop run. tokio also watches the loop's wakeup fd, and gives the hand
  back as soon as another source has work (idb results, for instance).
- **Background mode** (once an external loop drives evloop's, as with
  `fetch.lwt`, `fetch.eio` or `Fetch.use_external_loop ()`): tokio runs on a
  background thread and never touches OCaml values. A finished request goes
  into a queue and makes the loop's wakeup fd readable; the loop's next turn
  runs the callbacks. Each response crosses threads, which costs some
  throughput on small requests.

## The event loop at exit

On JS the host keeps running its event loop after the program's top level
returns. On native, the first request registers evloop's `at_exit` handler,
which runs the loop, which gives the same behaviour. Both backends then agree
on the edge cases (checked by `test/`):

| situation                                   | result                                   |
|---------------------------------------------|------------------------------------------|
| main code raises an uncaught exception      | dies at once (code 2), no callback runs  |
| a callback calls `exit n`                   | exits with `n`, pending requests dropped |
| a callback raises                           | `Fatal error: exception ...`, code 2     |

On native, "dies at once" relies on a hook: evloop wraps the runtime's
`Printexc.handle_uncaught_exception` named value to know the program is
crashing, since exit handlers also run in that case. On JS, exceptions from
callbacks are reported through js_of_ocaml's `caml_fatal_uncaught_exception`
and node then exits with code 2. In a browser, the error is reported and the
page keeps running.

`Fetch.run ()` (`Evloop.run`) is still available to wait at a specific point
(native only; it returns immediately on JS): it runs every source until none
has work left. There, an exception from a callback is re-raised by `run` and
can be caught. When it waits on the wakeup fd, it sleeps with the OCaml
runtime lock released, so other OCaml threads keep running.

## Lwt, Eio and servers

The at-exit loop only runs when the program ends, so a program whose event
loop never returns (a Lwt or Eio server) must use background mode and deliver
responses from its own loop. `fetch.lwt` and `fetch.eio` do both, through
`evloop.lwt` and `evloop.eio` (linking them makes evloop's loop external,
before any request):

```ocaml
(* Lwt *)
let* r = Fetch_lwt.req "https://example.com" in ...

(* Eio, in any fiber under Eio_main.run *)
match Fetch_eio.req "https://example.com" with ...
```

Lwt dispatches from one watcher for the whole program; with Eio, the fiber
waiting for a response dispatches meanwhile, or `Evloop_eio.start ~sw` runs
a dispatching fiber for the whole program (needed by idb). They watch
`Fetch.fd ()` (`Evloop.fd`: an eventfd that becomes readable when work is
ready) and call `Fetch.dispatch ()` (`Evloop.dispatch`), which runs the
callbacks of every ready response, and the work of the other sources. Any
other event loop can do the same: call `Fetch.use_external_loop ()` at
startup, then watch `Fetch.fd ()` and dispatch while `Fetch.pending ()` is
not 0 (`test/test_background.ml` does it with `Unix.select`). Requests
started before the switch still complete, but only through `Fetch.run` or
the at-exit loop. On JS/Wasm the host event loop delivers responses by
itself (`Fetch.fd` is `None`, the rest does nothing).

## ez_api engines

`ez_api.req_lwt` (`EzReqLwt`) and `ez_api.req_eio` (`EzReqEio`) take their
engine from a dune virtual library (`ez_api.req_lwt_dp`, which
`ez_api.req_lwt` re-exports, and `ez_api.req_eio`). Link `fetch.ez_api_lwt`
or `fetch.ez_api_eio` next to them to use fetch as that engine:

```
(executable (name main) (libraries ez_api.req_lwt fetch.ez_api_lwt ...))
(executable (name main) (libraries ez_api.req_eio fetch.ez_api_eio ...))
```

They follow the other ez_api engines: a non-2xx status is
`Error (code, Some body)`, a transport error `Error (-1, Some message)`
(Lwt), or the response `(-1, message, [])` (Eio, raw `get`/`post`), which the
typed calls turn into `Error (-1, _)`. A `content-type` in `~headers` wins
over `~content_type`. With Eio, `~net` and `~sw` are not used: requests run
on fetch's runtime, only the calling fiber waits. Native only for now.

## Installing

```sh
opam pin add fetch <url of this git repository>
```

Requirements:

- **OCaml ≥ 4.12**; OCaml 5 for `fetch.direct` (skipped on older versions).
- **evloop** (the event loop, shared with other libraries): install it
  first (`opam pin add evloop <its repository>`).
- **Rust ≥ 1.88** with cargo (`conf-rust-2021` checks that cargo exists,
  but distribution packages are often older; use [rustup](https://rustup.rs)
  in that case, cargo then reports the required version clearly).
- **Network access during the build**: cargo downloads the Rust crates from
  crates.io (exact versions from `Cargo.lock`). If opam's build sandbox is
  enabled (`opam option wrap-build-commands` is not `[]`), it blocks the
  network and the build fails.
- js_of_ocaml / wasm_of_ocaml are only needed to compile your own programs to
  JS / Wasm, not to install the library.

## Developing

Build requirements: OCaml ≥ 5 (≥ 4.12 without `fetch.direct`), dune, cargo,
js_of_ocaml and wasm_of_ocaml (with binaryen), and node to run the JS and
Wasm outputs. In this setup, all of these live in the `bench` opam switch.

`make` builds against evloop's source tree in `../evloop` (built there with
`make`) when it exists, through `OCAMLPATH`; otherwise against the installed
evloop.

```sh
make                  # dune build: native, bytecode, JS and Wasm
make release          # optimised build
make test             # dune test: every suite, every backend
make test-js          # the cram test of one backend: test-native, test-byte,
                      # test-js, test-wasm; test-direct for fetch.direct
make promote          # accept new cram test outputs (dune promote)
make clean
make FETCH_RS_FEATURES=gzip   # enable Cargo features of the Rust backend
```

```sh
dune build
./_build/default/example/direct.exe       https://example.com https://httpbin.org/delay/1
./_build/default/example/direct.bc.exe    https://example.com   # bytecode (byte_complete)
node _build/default/example/direct.bc.js  https://example.com
node _build/default/example/callbacks.bc.js https://example.com
node _build/default/example/direct.bc.wasm.js https://example.com   # Wasm
./_build/default/example/daemon.exe -every 5 https://example.com   # Ctrl-C to stop
node _build/default/example/daemon.bc.js -every 5 -n 3 https://example.com
```

## Tests

`dune test` (or `make test`) runs, with node for the test server
(`test/server.js`, started on a free port by each test, so tests run in
parallel):

- Alcotest suites, native and bytecode (`test/test_*.ml`): the shared cases
  in local mode and in background mode (with `Fetch.run` and with a
  `Unix.select` loop), exceptions coming out of `Fetch.run`, `fetch.direct`
  (`test_direct`, OCaml 5 only),
  `fetch.lwt` (alcotest-lwt, including the shared cases), `fetch.eio` (with
  Eio's default and POSIX backends), and the ez_api engines
  (`test/ez/`). The Lwt, Eio and ez_api suites are skipped when those
  libraries are not installed.
- Cram tests, one per backend (`test/native.t`, `byte.t`, `js.t`,
  `wasm.t`): the shared cases driven by the event loop (the at-exit loop on
  native, also in background mode; the JS event loop on JS/Wasm), and how a
  program ends: exit codes, "Fatal error" output, exit handlers
  (`test/crash.ml`, `exit_cb.ml`, `raise_at_exit.ml`, `exn_cb.ml`).
  `test/direct.t` (OCaml 5 only) does the same for an exception in a
  `fetch.direct` fiber (`exn_direct.ml`), on every backend. A `.t` file is the expected transcript; after a
  deliberate change of output, check the diff and accept it with
  `dune promote`.

The shared cases (`test/cases/cases.ml`) are written with callbacks, so the
same code runs under Alcotest on native, under Lwt, and from the JS event
loop on JS/Wasm. To run a program by hand:

```sh
node test/server.js &                         # port 8765, the default
./_build/default/test/run_cases.exe           # also .bc.exe, .bc.js, .bc.wasm.js
./_build/default/test/test_local.exe          # an Alcotest suite (starts its own server)
```

## JS and effects

Executables that use `fetch.direct` must enable effects in js_of_ocaml:

```
(executable
 (name main)
 (modes js)
 (js_of_ocaml
  (flags (:standard --effects=cps))
  (build_runtime_flags (:standard --effects=cps)))
 (libraries fetch.direct))
```

Executables that only use `fetch` should leave this out. The flag is set per
executable, and dune compiles each library once per effects mode
(`.fetch.objs/jsoo/effects=cps/` vs `effects=disabled/`), so both kinds of
program can live in the same project. With `--profile release`, the
callback-only example is about 90 KB of JS and the direct-style one about
97 KB.

## Wasm (wasm_of_ocaml)

WebAssembly has no network access of its own, so the Wasm backend also uses
the host `fetch`. The split is:

- `fetch_runtime_wasm.js` calls `fetch` and only handles plain JS values;
- `fetch_runtime.wat` converts the OCaml arguments to JS values, and builds
  `Ok (status, headers, body)` / `Error msg` when JS calls back. Bodies are
  copied into an OCaml string, or wrapped as a Bigarray without copying
  (`caml_ba_char_of_typed_array`).
- The OCaml callback runs under the runtime's `caml_main`, so an exception
  escaping it is reported like an uncaught exception at top level (exit code
  2), the same as on native and js_of_ocaml.

`Sys.backend_type` is `Other _` on Wasm too, so Wasm follows the JS
behaviour: no at-exit loop, the host event loop does the work.

Effects: wasm_of_ocaml uses JSPI by default, which needs node ≥ 25 or Chrome
≥ 137. With older engines, executables using `fetch.direct` need
`(wasm_of_ocaml (flags (:standard --effects=cps)))`, as in `example/dune`.

Every example and test is also built for Wasm (`.bc.wasm.js`):

```sh
node _build/default/test/run_cases.bc.wasm.js       # with node test/server.js running
node _build/default/example/direct.bc.wasm.js https://example.com
```

## Native build options

- TLS is rustls with the **ring** crypto provider and the platform certificate
  verifier (system trust store; `SSL_CERT_FILE` / `SSL_CERT_DIR` are honoured).
- gzip is off by default: native requests don't ask for compression. Enable it
  with `FETCH_RS_FEATURES=gzip dune build`; responses are then decompressed
  transparently. On JS, the host `fetch` always handles compression.

## Notes

- Plain `(modes byte)` executables need `CAML_LD_LIBRARY_PATH=_build/default/src`
  at runtime (for `dllfetch_rs.so`). `byte_complete` avoids that.
- Callbacks always run on the OCaml thread that dispatches. Requests can be
  started from any callback.
- Native, background mode: the background thread starts with the first
  request and is not inherited by `fork`. A process that forks (e.g. a pre-forking server) must
  only make requests in the children, or fork before the first request.
