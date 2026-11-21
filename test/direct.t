fetch.direct (OCaml 5 only): an exception in a fiber resumed by the event
loop. On native and bytecode it comes out of an explicit Fetch.run; on JS
and Wasm, Fetch.run returns at once and the exception kills the program.

  $ export FETCH_TEST_URL=$(sh ./server.sh start)

  $ ./exn_direct.exe
  caught Boom from run: OK
  main fiber finished (native: resumed by the loop at exit)

  $ ./exn_direct.bc.exe
  caught Boom from run: OK
  main fiber finished (native: resumed by the loop at exit)

  $ node ./exn_direct.bc.js
  run returned (JS: expected, Boom kills the program later)
  Fatal error: exception Dune__exe__Exn_direct.Boom
  [2]

  $ node ./exn_direct.bc.wasm.js
  run returned (JS: expected, Boom kills the program later)
  Fatal error: exception Dune__exe__Exn_direct.Boom
  [2]

  $ sh ./server.sh stop
