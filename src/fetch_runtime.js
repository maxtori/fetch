//Provides: caml_fetch_callback
//Requires: caml_callback, caml_fatal_uncaught_exception

function caml_fetch_callback(cb, arg) {
  try {
    caml_callback(cb, [arg]);
  } catch (e) {
    caml_fatal_uncaught_exception(e);
    var p = globalThis.process;
    if (p && typeof p.exit === "function") p.exit(2);
  }
}

//Provides: caml_fetch_init
//Requires: caml_jsstring_of_string, caml_uint8_array_of_string

function caml_fetch_init(meth, headers, body) {
  var h = [];
  for (var i = 1; i < headers.length; i++)
    h.push([
      caml_jsstring_of_string(headers[i][1]),
      caml_jsstring_of_string(headers[i][2]),
    ]);
  var init = { method: caml_jsstring_of_string(meth), headers: h };
  if (body !== 0) init.body = caml_uint8_array_of_string(body[1]);
  return init;
}

//Provides: caml_fetch_error_message
function caml_fetch_error_message(e) {
  var msg = String((e && e.message) || e);
  for (var c = e && e.cause; c; c = c.cause)
    msg += ": " + String(c.message || c.code || c);
  return msg;
}

//Provides: caml_fetch_headers_string

function caml_fetch_headers_string(resp) {
  var hs = "";
  resp.headers.forEach(function (v, k) {
    hs += k + ":" + v + "\n";
  });
  return hs;
}

//Provides: caml_fetch_timeout_ms

function caml_fetch_timeout_ms(timeout) {
  return timeout >= 0 && timeout * 1000 <= 2147483647 ? Math.round(timeout * 1000) : -1;
}

//Provides: caml_fetch_do_request
//Requires: caml_jsstring_of_string, caml_string_of_jsstring
//Requires: caml_string_of_jsbytes, caml_string_of_uint8_array, caml_ba_create_unsafe
//Requires: caml_fetch_callback, caml_fetch_init, caml_fetch_error_message
//Requires: caml_fetch_headers_string, caml_fetch_timeout_ms

function caml_fetch_do_request(meth, url, headers, body, timeout, cb, bigstring) {
  var init = caml_fetch_init(meth, headers, body);

  var ms = caml_fetch_timeout_ms(timeout);
  var signal = null;
  if (ms >= 0) init.signal = signal = globalThis.AbortSignal.timeout(ms);

  function error_message(e) {

    if (signal && signal.aborted && signal.reason === e) return "timeout";
    return caml_fetch_error_message(e);
  }

  fetch(caml_jsstring_of_string(url), init)
    .then(function (resp) {
      return resp.arrayBuffer().then(function (buf) {
        return [resp.status, caml_fetch_headers_string(resp), new Uint8Array(buf)];
      });
    })
    .then(
      function (r) {
        var b = bigstring
          ? caml_ba_create_unsafe(12 , 0 , [r[2].length], r[2])
          : caml_string_of_uint8_array(r[2]);

        caml_fetch_callback(cb, [0, [0, r[0], caml_string_of_jsbytes(r[1]), b]]);
      },
      function (e) {

        caml_fetch_callback(cb, [1, caml_string_of_jsstring(error_message(e))]);
      },
    );
  return 0;
}

//Provides: caml_fetch_request
//Requires: caml_fetch_do_request
function caml_fetch_request(meth, url, headers, body, timeout, cb) {
  return caml_fetch_do_request(meth, url, headers, body, timeout, cb, false);
}

//Provides: caml_fetch_request_bigstring
//Requires: caml_fetch_do_request
function caml_fetch_request_bigstring(meth, url, headers, body, timeout, cb) {
  return caml_fetch_do_request(meth, url, headers, body, timeout, cb, true);
}

//Provides: caml_fetch_stream_open
//Requires: caml_jsstring_of_string, caml_string_of_jsstring, caml_string_of_jsbytes
//Requires: caml_fetch_callback, caml_fetch_init, caml_fetch_error_message
//Requires: caml_fetch_headers_string, caml_fetch_timeout_ms

function caml_fetch_stream_open(meth, url, headers, body, timeout, cb) {
  var init = caml_fetch_init(meth, headers, body);
  var st = { ctl: new globalThis.AbortController(), reader: null, closed: false };
  init.signal = st.ctl.signal;
  var timed_out = false;
  var ms = caml_fetch_timeout_ms(timeout);
  var timer = ms >= 0 ? globalThis.setTimeout(function () {
    timed_out = true;
    st.ctl.abort();
  }, ms) : null;
  fetch(caml_jsstring_of_string(url), init).then(
    function (resp) {
      globalThis.clearTimeout(timer);
      st.reader = resp.body ? resp.body.getReader() : null;
      var hs = caml_string_of_jsbytes(caml_fetch_headers_string(resp));
      caml_fetch_callback(cb, [0, [0, resp.status, hs, 0]]);
    },
    function (e) {
      globalThis.clearTimeout(timer);
      var msg = timed_out ? "timeout" : st.closed ? "closed" : caml_fetch_error_message(e);
      caml_fetch_callback(cb, [1, caml_string_of_jsstring(msg)]);
    },
  );
  return st;
}

//Provides: caml_fetch_stream_do_read
//Requires: caml_string_of_jsstring, caml_string_of_uint8_array, caml_ba_create_unsafe
//Requires: caml_fetch_callback, caml_fetch_error_message, caml_fetch_timeout_ms

function caml_fetch_stream_do_read(st, timeout, cb, bigstring) {
  function deliver(r) {
    caml_fetch_callback(cb, r);
  }
  if (!st.reader) {

    var r = st.closed ? [1, caml_string_of_jsstring("closed")] : [0, 0];
    globalThis.setTimeout(function () { deliver(r); }, 0);
    return 0;
  }
  var done = false;
  var ms = caml_fetch_timeout_ms(timeout);
  var timer = ms >= 0 ? globalThis.setTimeout(function () {
    if (done) return;
    done = true;
    st.closed = true;
    st.ctl.abort();
    deliver([1, caml_string_of_jsstring("timeout")]);
  }, ms) : null;
  st.reader.read().then(
    function (r) {
      if (done) return;
      done = true;
      globalThis.clearTimeout(timer);
      if (r.done) return deliver([0, 0]);
      var c = bigstring
        ? caml_ba_create_unsafe(12 , 0 , [r.value.length], r.value)
        : caml_string_of_uint8_array(r.value);
      deliver([0, [0, c]]);
    },
    function (e) {
      if (done) return;
      done = true;
      globalThis.clearTimeout(timer);
      deliver([1, caml_string_of_jsstring(st.closed ? "closed" : caml_fetch_error_message(e))]);
    },
  );
  return 0;
}

//Provides: caml_fetch_stream_read
//Requires: caml_fetch_stream_do_read
function caml_fetch_stream_read(st, timeout, cb) {
  return caml_fetch_stream_do_read(st, timeout, cb, false);
}

//Provides: caml_fetch_stream_read_bigstring
//Requires: caml_fetch_stream_do_read
function caml_fetch_stream_read_bigstring(st, timeout, cb) {
  return caml_fetch_stream_do_read(st, timeout, cb, true);
}

//Provides: caml_fetch_stream_close
function caml_fetch_stream_close(st) {
  if (!st.closed) {
    st.closed = true;
    st.ctl.abort();
  }
  return 0;
}

//Provides: caml_fetch_after
//Requires: caml_fetch_callback

function caml_fetch_after(seconds, cb) {
  var MAX = 2147483647;
  var timer = { handle: null };
  function arm(ms) {
    var step = Math.min(ms, MAX);
    timer.handle = setTimeout(function () {
      if (ms > step) arm(ms - step);
      else caml_fetch_callback(cb, 0);
    }, step);
  }
  arm(Math.max(0, seconds * 1000));
  return timer;
}

//Provides: caml_fetch_cancel_timer
function caml_fetch_cancel_timer(timer) {
  globalThis.clearTimeout(timer.handle);
  return 0;
}

//Provides: caml_fetch_dispatch
function caml_fetch_dispatch(_unit) {
  return 0;
}

//Provides: caml_fetch_use_background
function caml_fetch_use_background(_unit) {
  return 0;
}

//Provides: caml_fetch_run_local_until

function caml_fetch_run_local_until(_fd) {
  return 0;
}

//Provides: caml_fetch_set_wake_fd
function caml_fetch_set_wake_fd(_fd) {
  return 0;
}
