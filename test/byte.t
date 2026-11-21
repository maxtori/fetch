How programs behave on the byte backend: the shared cases driven by the
event loop, and how a program ends (exit code, fatal errors).

  $ export FETCH_TEST_URL=$(sh ./server.sh start)

The shared cases (cases/cases.ml), one after the other, from the event loop
that runs at exit:

  $ ./run_cases.bc.exe
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

Same in background mode (tokio on its own thread):

  $ FETCH_BG=1 ./run_cases.bc.exe
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

  $ ./crash.bc.exe
  Fatal error: exception Failure("main crashed")
  [2]

exit from a callback exits at once with that code, abandoning the other
request.

  $ ./exit_cb.bc.exe
  exiting with 3
  [3]

A callback raises: the program dies with that exception (exit code 2),
output buffered before is flushed, and the loop does not go on with the
other request.

  $ ./raise_at_exit.bc.exe
  buffered (not flushed) output
  callback 1 raising Boom
  Fatal error: exception Dune__exe__Raise_at_exit.Boom
  [2]

An exception from a callback comes out of an explicit Fetch.run; a second
Fetch.run completes the other request.

  $ ./exn_cb.bc.exe
  caught Boom from run: OK
  second request done

  $ sh ./server.sh stop
