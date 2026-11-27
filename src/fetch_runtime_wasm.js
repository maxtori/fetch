//Provides: caml_fetch_wasm_new_array
function caml_fetch_wasm_new_array() {
  return [];
}

//Provides: caml_fetch_wasm_push_header
function caml_fetch_wasm_push_header(arr, name, value) {
  arr.push([name, value]);
}

//Provides: caml_fetch_wasm_after

function caml_fetch_wasm_after(seconds, done, ctx) {
  var MAX = 2147483647;
  var timer = { handle: null };
  function arm(ms) {
    var step = Math.min(ms, MAX);
    timer.handle = setTimeout(function () {
      if (ms > step) arm(ms - step);
      else done(ctx);
    }, step);
  }
  arm(Math.max(0, seconds * 1000));
  return timer;
}

//Provides: caml_fetch_wasm_cancel_timer
function caml_fetch_wasm_cancel_timer(timer) {
  globalThis.clearTimeout(timer.handle);
}

//Provides: caml_fetch_wasm_start

function caml_fetch_wasm_start(meth, url, headers, body, timeout, done, ctx) {
  var init = { method: meth, headers: headers };
  if (body !== null && body !== undefined) init.body = body;

  var signal = null;
  if (timeout >= 0 && timeout * 1000 <= 2147483647)
    init.signal = signal = globalThis.AbortSignal.timeout(Math.round(timeout * 1000));

  function error_message(e) {

    if (signal && signal.aborted && signal.reason === e) return "timeout";
    var msg = String((e && e.message) || e);
    for (var c = e && e.cause; c; c = c.cause)
      msg += ": " + String(c.message || c.code || c);
    return msg;
  }

  fetch(url, init)
    .then(function (resp) {
      return resp.arrayBuffer().then(function (buf) {

        var hs = "";
        resp.headers.forEach(function (v, k) {
          hs += k + ":" + v + "\n";
        });
        return [resp.status, hs, new Uint8Array(buf)];
      });
    })
    .then(
      function (r) {
        done(ctx, r[0], r[1], r[2], null);
      },
      function (e) {
        done(ctx, 0, null, null, error_message(e));
      },
    );
}

//Provides: caml_fetch_wasm_timeout_ms

function caml_fetch_wasm_timeout_ms(timeout) {
  return timeout >= 0 && timeout * 1000 <= 2147483647 ? Math.round(timeout * 1000) : -1;
}

//Provides: caml_fetch_wasm_error_message
function caml_fetch_wasm_error_message(e) {
  var msg = String((e && e.message) || e);
  for (var c = e && e.cause; c; c = c.cause)
    msg += ": " + String(c.message || c.code || c);
  return msg;
}

//Provides: caml_fetch_wasm_stream_open
//Requires: caml_fetch_wasm_timeout_ms, caml_fetch_wasm_error_message

function caml_fetch_wasm_stream_open(meth, url, headers, body, timeout, done, ctx) {
  var st = { ctl: new globalThis.AbortController(), reader: null, closed: false };
  var init = { method: meth, headers: headers, signal: st.ctl.signal };
  if (body !== null && body !== undefined) init.body = body;
  var timed_out = false;
  var ms = caml_fetch_wasm_timeout_ms(timeout);
  var timer = ms >= 0 ? globalThis.setTimeout(function () {
    timed_out = true;
    st.ctl.abort();
  }, ms) : null;
  fetch(url, init).then(
    function (resp) {
      globalThis.clearTimeout(timer);
      st.reader = resp.body ? resp.body.getReader() : null;
      var hs = "";
      resp.headers.forEach(function (v, k) {
        hs += k + ":" + v + "\n";
      });
      done(ctx, resp.status, hs, null, null);
    },
    function (e) {
      globalThis.clearTimeout(timer);
      done(ctx, 0, null, null,
           timed_out ? "timeout" : st.closed ? "closed" : caml_fetch_wasm_error_message(e));
    },
  );
  return st;
}

//Provides: caml_fetch_wasm_stream_read
//Requires: caml_fetch_wasm_timeout_ms, caml_fetch_wasm_error_message

function caml_fetch_wasm_stream_read(st, timeout, done, ctx) {
  if (!st.reader) {

    var closed = st.closed;
    globalThis.setTimeout(function () {
      if (closed) done(ctx, 2, null, "closed");
      else done(ctx, 0, null, null);
    }, 0);
    return;
  }
  var finished = false;
  var ms = caml_fetch_wasm_timeout_ms(timeout);
  var timer = ms >= 0 ? globalThis.setTimeout(function () {
    if (finished) return;
    finished = true;
    st.closed = true;
    st.ctl.abort();
    done(ctx, 2, null, "timeout");
  }, ms) : null;
  st.reader.read().then(
    function (r) {
      if (finished) return;
      finished = true;
      globalThis.clearTimeout(timer);
      if (r.done) done(ctx, 0, null, null);
      else done(ctx, 1, r.value, null);
    },
    function (e) {
      if (finished) return;
      finished = true;
      globalThis.clearTimeout(timer);
      done(ctx, 2, null, st.closed ? "closed" : caml_fetch_wasm_error_message(e));
    },
  );
}

//Provides: caml_fetch_wasm_stream_close
function caml_fetch_wasm_stream_close(st) {
  if (!st.closed) {
    st.closed = true;
    st.ctl.abort();
  }
}
