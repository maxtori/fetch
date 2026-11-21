How programs behave on the js backend: the shared cases driven by the
event loop, and how a program ends (exit code, fatal errors).

  $ export FETCH_TEST_URL=$(sh ./server.sh start)

The shared cases (cases/cases.ml), one after the other, from the event loop
(the JS one):

  $ node ./run_cases.bc.js
  ok echo
  ok headers
  ok bigstring body
  ok non-2xx status
  ok connection refused
  ok concurrent requests
  ok nested requests
  ok timers
  ok timeout
  ok cancel
  ok stream
  ok stream, bigstring chunks
  ok stream timeouts
  ok stream close
  all cases passed

The main program dies from an uncaught exception: the pending request is
abandoned, its callback never runs.

  $ node ./crash.bc.js
  Fatal error: exception Failure("main crashed")
  [2]

exit from a callback exits at once with that code, abandoning the other
request.

  $ node ./exit_cb.bc.js
  exiting with 3
  [3]

A callback raises: the program dies with that exception (exit code 2),
output buffered before is flushed, and the loop does not go on with the
other request.

  $ node ./raise_at_exit.bc.js
  buffered (not flushed) output
  callback 1 raising Boom
  Fatal error: exception Dune__exe__Raise_at_exit.Boom
  [2]

Fetch.run returns at once (the JS event loop delivers responses later), so
an exception from a callback kills the program.

  $ node ./exn_cb.bc.js
  run returned (JS: expected, Boom kills the program later)
  Fatal error: exception Dune__exe__Exn_cb.Boom
  [2]

  $ sh ./server.sh stop
