#!/bin/sh
# Test server (server.js, next to this script) on a free port.
#   server.sh start      start it, print its URL, write its pid to ./server.pid
#   server.sh stop       stop it
# Used by the cram tests, whose programs read $FETCH_TEST_URL.
set -u
dir=$(dirname "$0")

start() {
  out=$(mktemp)
  node "$dir/server.js" 0 >"$out" 2>&1 </dev/null &
  echo $! >server.pid
  for _ in $(seq 100); do
    port=$(sed -n 's/^listening //p' "$out")
    if [ -n "$port" ]; then rm -f "$out"; echo "http://localhost:$port"; return 0; fi
    sleep 0.05
  done
  cat "$out" >&2; rm -f "$out"
  echo "server.sh: the test server did not start" >&2
  return 1
}

stop() {
  [ -f server.pid ] && kill "$(cat server.pid)" 2>/dev/null
  rm -f server.pid
}

case ${1-} in
  start) start ;;
  stop) stop ;;
  *) echo "usage: server.sh start|stop" >&2; exit 2 ;;
esac
