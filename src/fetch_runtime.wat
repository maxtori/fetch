;; wasm_of_ocaml implementation of the Fetch primitives.
;;
;; The network request itself is done by the host `fetch` (JS helper in
;; fetch_runtime_wasm.js, which only sees plain JS values). This module
;; converts between OCaml values and JS values:
;; - OCaml arguments -> JS strings, a JS array of [name, value], a Uint8Array;
;; - JS results -> Ok (status, headers, body) | Error msg, then calls the
;;   OCaml callback.
;; The callback runs under the runtime's `caml_main`, so an exception escaping
;; it is reported exactly like an uncaught exception at top level (Printexc
;; handler, exit handlers, "Fatal error: exception ...", exit code 2), as with
;; the native and js_of_ocaml backends.

(module
  ;; The runtime's block type. It must be this exact type (mutable fields
  ;; included) for casts to it to succeed, even though this module never
  ;; writes to a block.
  (type $block (array (mut (ref eq))))

  ;; OCaml <-> JS conversions from the runtime. User runtime files are merged
  ;; after the standard runtime, whose functions are then all exports of the
  ;; module "env".
  (import "env" "wrap" (func $wrap (param anyref) (result (ref eq))))
  (import "env" "unwrap" (func $unwrap (param (ref eq)) (result anyref)))
  (import "env" "caml_jsstring_of_string" (func $caml_jsstring_of_string (param (ref eq)) (result (ref eq))))
  (import "env" "caml_string_of_jsstring" (func $caml_string_of_jsstring (param (ref eq)) (result (ref eq))))
  (import "env" "caml_string_of_jsbytes" (func $caml_string_of_jsbytes (param (ref eq)) (result (ref eq))))
  (import "env" "caml_uint8_array_of_string" (func $caml_uint8_array_of_string (param (ref eq)) (result (ref eq))))
  (import "env" "caml_string_of_uint8_array" (func $caml_string_of_uint8_array (param (ref eq)) (result (ref eq))))
  (import "env" "caml_ba_char_of_typed_array" (func $caml_ba_char_of_typed_array (param (ref eq)) (result (ref eq))))
  (import "env" "caml_callback_1" (func $caml_callback_1 (param (ref eq)) (param (ref eq)) (result (ref eq))))
  (import "env" "caml_main" (func $caml_main (param (ref func))))
  (import "env" "Double_val" (func $Double_val (param (ref eq)) (result f64)))

  ;; JS helpers (fetch_runtime_wasm.js)
  (import "js" "caml_fetch_wasm_new_array" (func $new_array (result anyref)))
  (import "js" "caml_fetch_wasm_push_header" (func $push_header (param anyref) (param anyref) (param anyref)))
  (import "js" "caml_fetch_wasm_start" (func $start (param anyref) (param anyref) (param anyref) (param anyref) (param f64) (param funcref) (param anyref)))
  (import "js" "caml_fetch_wasm_after" (func $after (param f64) (param funcref) (param anyref) (result anyref)))
  (import "js" "caml_fetch_wasm_cancel_timer" (func $cancel_timer (param anyref)))
  (import "js" "caml_fetch_wasm_stream_open" (func $stream_open (param anyref) (param anyref) (param anyref) (param anyref) (param f64) (param funcref) (param anyref) (result anyref)))
  (import "js" "caml_fetch_wasm_stream_read" (func $stream_read (param anyref) (param f64) (param funcref) (param anyref)))
  (import "js" "caml_fetch_wasm_stream_close" (func $stream_close (param anyref)))

  ;; JS calls this back: (ctx, status, headers, body, error). On success
  ;; [error] is null; on failure only [error] is meaningful.
  (type $done
    (func (param anyref) (param i32) (param anyref) (param anyref) (param anyref)))

  (type $timer_done (func (param anyref)))

  ;; Stream reads: (ctx, kind, chunk, error), kind 1 = a chunk (Uint8Array),
  ;; 0 = end of the body, 2 = error (message).
  (type $chunk_done
    (func (param anyref) (param i32) (param anyref) (param anyref)))

  (elem declare func $done_string $done_bigstring $done_timer $done_head $chunk_string $chunk_bigstring $deliver)

  (func $js_string (param $s (ref eq)) (result anyref)
    (call $unwrap
      (call $caml_jsstring_of_string
        (local.get $s))))

  ;; A request, or with [$stream] set, a stream (then returns the stream).
  (func $request
    (param $meth (ref eq)) (param $url (ref eq)) (param $headers (ref eq)) (param $body (ref eq)) (param $timeout (ref eq)) (param $cb (ref eq)) (param $done (ref $done)) (param $stream i32) (result (ref eq))
    (local $hs (ref $block))
    (local $h (ref $block))
    (local $arr anyref)
    (local $i i32)
    (local $n i32)
    (local $js_body anyref)
    ;; headers: OCaml (string * string) array -> JS array of [name, value]
    (local.set $hs
      (ref.cast (ref $block)
        (local.get $headers)))
    (local.set $arr
      (call $new_array))
    (local.set $n
      (array.len
        (local.get $hs)))
    (local.set $i
      (i32.const 1)) ;; field 0 is the block tag
    (block $done_loop
      (loop $loop
        (br_if $done_loop
          (i32.ge_u
            (local.get $i)
            (local.get $n)))
        (local.set $h
          (ref.cast (ref $block)
            (array.get $block
              (local.get $hs)
              (local.get $i))))
        (call $push_header
          (local.get $arr)
          (call $js_string
            (array.get $block
              (local.get $h)
              (i32.const 1)))
          (call $js_string
            (array.get $block
              (local.get $h)
              (i32.const 2))))
        (local.set $i
          (i32.add
            (local.get $i)
            (i32.const 1)))
        (br $loop)))
    ;; body: None (immediate 0) or Some s -> null or Uint8Array
    (if
      (ref.test (ref $block)
        (local.get $body))
      (then
        (local.set $js_body
          (call $unwrap
            (call $caml_uint8_array_of_string
              (array.get $block
                (ref.cast (ref $block)
                  (local.get $body))
                (i32.const 1)))))))
    (if (result (ref eq))
      (local.get $stream)
      (then
        (call $wrap
          (call $stream_open
            (call $js_string
              (local.get $meth))
            (call $js_string
              (local.get $url))
            (local.get $arr)
            (local.get $js_body)
            (call $Double_val
              (local.get $timeout))
            (local.get $done)
            (local.get $cb))))
      (else
        (call $start
          (call $js_string
            (local.get $meth))
          (call $js_string
            (local.get $url))
          (local.get $arr)
          (local.get $js_body)
          ;; seconds, negative for none
          (call $Double_val
            (local.get $timeout))
          (local.get $done)
          ;; the OCaml callback travels through JS as an opaque reference
          (local.get $cb))
        (ref.i31
          (i32.const 0)))))

  (func (export "caml_fetch_request")
    (param $meth (ref eq)) (param $url (ref eq)) (param $headers (ref eq)) (param $body (ref eq)) (param $timeout (ref eq)) (param $cb (ref eq)) (result (ref eq))
    (call $request
      (local.get $meth)
      (local.get $url)
      (local.get $headers)
      (local.get $body)
      (local.get $timeout)
      (local.get $cb)
      (ref.func $done_string)
      (i32.const 0)))

  (func (export "caml_fetch_request_bigstring")
    (param $meth (ref eq)) (param $url (ref eq)) (param $headers (ref eq)) (param $body (ref eq)) (param $timeout (ref eq)) (param $cb (ref eq)) (result (ref eq))
    (call $request
      (local.get $meth)
      (local.get $url)
      (local.get $headers)
      (local.get $body)
      (local.get $timeout)
      (local.get $cb)
      (ref.func $done_bigstring)
      (i32.const 0)))

  ;; Streams: same arguments as a request; returns the stream (a JS object)
  (func (export "caml_fetch_stream_open")
    (param $meth (ref eq)) (param $url (ref eq)) (param $headers (ref eq)) (param $body (ref eq)) (param $timeout (ref eq)) (param $cb (ref eq)) (result (ref eq))
    (call $request
      (local.get $meth)
      (local.get $url)
      (local.get $headers)
      (local.get $body)
      (local.get $timeout)
      (local.get $cb)
      (ref.func $done_head)
      (i32.const 1)))

  ;; stream -> timeout:float -> ((chunk option, string) result -> unit) -> unit
  (func (export "caml_fetch_stream_read")
    (param $stream (ref eq)) (param $timeout (ref eq)) (param $cb (ref eq)) (result (ref eq))
    (call $stream_read
      (call $unwrap
        (local.get $stream))
      (call $Double_val
        (local.get $timeout))
      (ref.func $chunk_string)
      (local.get $cb))
    (ref.i31
      (i32.const 0)))

  (func (export "caml_fetch_stream_read_bigstring")
    (param $stream (ref eq)) (param $timeout (ref eq)) (param $cb (ref eq)) (result (ref eq))
    (call $stream_read
      (call $unwrap
        (local.get $stream))
      (call $Double_val
        (local.get $timeout))
      (ref.func $chunk_bigstring)
      (local.get $cb))
    (ref.i31
      (i32.const 0)))

  (func (export "caml_fetch_stream_close")
    (param $stream (ref eq)) (result (ref eq))
    (call $stream_close
      (call $unwrap
        (local.get $stream)))
    (ref.i31
      (i32.const 0)))

  ;; Builds the OCaml result, then calls the callback under caml_main.
  (global $pending_cb (mut (ref null eq))
    (ref.null eq))
  (global $pending_res (mut (ref null eq))
    (ref.null eq))

  (func $deliver (result (ref eq))
    (call $caml_callback_1
      (ref.as_non_null
        (global.get $pending_cb))
      (ref.as_non_null
        (global.get $pending_res))))

  (func $finish
    (param $ctx anyref) (param $status i32) (param $headers anyref) (param $body (ref eq)) (param $err anyref)
    (global.set $pending_res
      (if (result (ref eq))
        (ref.is_null
          (local.get $err))
        (then
          ;; Ok (status, headers, body)
          (array.new_fixed $block 2
            (ref.i31
              (i32.const 0))
            (array.new_fixed $block 4
              (ref.i31
                (i32.const 0))
              (ref.i31
                (local.get $status))
              (call $caml_string_of_jsbytes
                (call $wrap
                  (local.get $headers)))
              (local.get $body))))
        (else
          ;; Error msg
          (array.new_fixed $block 2
            (ref.i31
              (i32.const 1))
            (call $caml_string_of_jsstring
              (call $wrap
                (local.get $err)))))))
    (global.set $pending_cb
      (ref.cast (ref eq)
        (local.get $ctx)))
    (call $caml_main
      (ref.func $deliver))
    (global.set $pending_cb
      (ref.null eq))
    (global.set $pending_res
      (ref.null eq)))

  (func $done_string (type $done)
    (param $ctx anyref) (param $status i32) (param $headers anyref) (param $body anyref) (param $err anyref)
    (call $finish
      (local.get $ctx)
      (local.get $status)
      (local.get $headers)
      (if (result (ref eq))
        (ref.is_null
          (local.get $err))
        (then
          (call $caml_string_of_uint8_array
            (call $wrap
              (local.get $body))))
        (else
          (ref.i31
            (i32.const 0))))
      (local.get $err)))

  (func $done_bigstring (type $done)
    (param $ctx anyref) (param $status i32) (param $headers anyref) (param $body anyref) (param $err anyref)
    (call $finish
      (local.get $ctx)
      (local.get $status)
      (local.get $headers)
      ;; zero copy: the Bigarray wraps the response's Uint8Array
      (if (result (ref eq))
        (ref.is_null
          (local.get $err))
        (then
          (call $caml_ba_char_of_typed_array
            (call $wrap
              (local.get $body))))
        (else
          (ref.i31
            (i32.const 0))))
      (local.get $err)))

  ;; Timers: float -> (unit -> unit) -> timer, the timer being the JS object
  ;; from caml_fetch_wasm_after
  (func (export "caml_fetch_after")
    (param $seconds (ref eq)) (param $cb (ref eq)) (result (ref eq))
    (call $wrap
      (call $after
        (call $Double_val
          (local.get $seconds))
        (ref.func $done_timer)
        (local.get $cb))))

  ;; timer -> unit
  (func (export "caml_fetch_cancel_timer")
    (param $timer (ref eq)) (result (ref eq))
    (call $cancel_timer
      (call $unwrap
        (local.get $timer)))
    (ref.i31
      (i32.const 0)))

  ;; Stream headers: Ok (status, headers, ()) | Error msg
  (func $done_head (type $done)
    (param $ctx anyref) (param $status i32) (param $headers anyref) (param $body anyref) (param $err anyref)
    (call $finish
      (local.get $ctx)
      (local.get $status)
      (local.get $headers)
      (ref.i31
        (i32.const 0))
      (local.get $err)))

  ;; Calls the callback [ctx] with [res] under caml_main.
  (func $call_with (param $ctx anyref) (param $res (ref eq))
    (global.set $pending_res
      (local.get $res))
    (global.set $pending_cb
      (ref.cast (ref eq)
        (local.get $ctx)))
    (call $caml_main
      (ref.func $deliver))
    (global.set $pending_cb
      (ref.null eq))
    (global.set $pending_res
      (ref.null eq)))

  ;; Ok (Some chunk) | Ok None | Error msg, the chunk being [$value] (built by
  ;; the caller from the Uint8Array)
  (func $chunk_result (param $kind i32) (param $value (ref eq)) (param $err anyref) (result (ref eq))
    (if (result (ref eq))
      (i32.eq
        (local.get $kind)
        (i32.const 1))
      (then
        (array.new_fixed $block 2
          (ref.i31
            (i32.const 0))
          (array.new_fixed $block 2
            (ref.i31
              (i32.const 0))
            (local.get $value))))
      (else
        (if (result (ref eq))
          (i32.eqz
            (local.get $kind))
          (then
            (array.new_fixed $block 2
              (ref.i31
                (i32.const 0))
              (ref.i31
                (i32.const 0))))
          (else
            (array.new_fixed $block 2
              (ref.i31
                (i32.const 1))
              (call $caml_string_of_jsstring
                (call $wrap
                  (local.get $err)))))))))

  (func $chunk_string (type $chunk_done)
    (param $ctx anyref) (param $kind i32) (param $chunk anyref) (param $err anyref)
    (call $call_with
      (local.get $ctx)
      (call $chunk_result
        (local.get $kind)
        (if (result (ref eq))
          (i32.eq
            (local.get $kind)
            (i32.const 1))
          (then
            (call $caml_string_of_uint8_array
              (call $wrap
                (local.get $chunk))))
          (else
            (ref.i31
              (i32.const 0))))
        (local.get $err))))

  (func $chunk_bigstring (type $chunk_done)
    (param $ctx anyref) (param $kind i32) (param $chunk anyref) (param $err anyref)
    (call $call_with
      (local.get $ctx)
      (call $chunk_result
        (local.get $kind)
        ;; zero copy: the Bigarray wraps the chunk's Uint8Array
        (if (result (ref eq))
          (i32.eq
            (local.get $kind)
            (i32.const 1))
          (then
            (call $caml_ba_char_of_typed_array
              (call $wrap
                (local.get $chunk))))
          (else
            (ref.i31
              (i32.const 0))))
        (local.get $err))))

  ;; Calls the callback with () under caml_main.
  (func $done_timer (type $timer_done)
    (param $ctx anyref)
    (global.set $pending_res
      (ref.i31
        (i32.const 0)))
    (global.set $pending_cb
      (ref.cast (ref eq)
        (local.get $ctx)))
    (call $caml_main
      (ref.func $deliver))
    (global.set $pending_cb
      (ref.null eq))
    (global.set $pending_res
      (ref.null eq)))

  ;; The JS event loop does the scheduling: nothing to run here (false).
  (func (export "caml_fetch_run_local_until") (param $_fd (ref eq)) (result (ref eq))
    (ref.i31
      (i32.const 0)))

  (func (export "caml_fetch_set_wake_fd") (param $_fd (ref eq)) (result (ref eq))
    (ref.i31
      (i32.const 0)))

  ;; The JS event loop delivers responses: nothing to dispatch, no fd (None).
  (func (export "caml_fetch_dispatch") (param $_unit (ref eq)) (result (ref eq))
    (ref.i31
      (i32.const 0)))

  (func (export "caml_fetch_use_background") (param $_unit (ref eq)) (result (ref eq))
    (ref.i31
      (i32.const 0))))
