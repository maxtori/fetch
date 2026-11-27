(module

  (type $block (array (mut (ref eq))))

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

  (import "js" "caml_fetch_wasm_new_array" (func $new_array (result anyref)))
  (import "js" "caml_fetch_wasm_push_header" (func $push_header (param anyref) (param anyref) (param anyref)))
  (import "js" "caml_fetch_wasm_start" (func $start (param anyref) (param anyref) (param anyref) (param anyref) (param f64) (param funcref) (param anyref)))
  (import "js" "caml_fetch_wasm_after" (func $after (param f64) (param funcref) (param anyref) (result anyref)))
  (import "js" "caml_fetch_wasm_cancel_timer" (func $cancel_timer (param anyref)))
  (import "js" "caml_fetch_wasm_stream_open" (func $stream_open (param anyref) (param anyref) (param anyref) (param anyref) (param f64) (param funcref) (param anyref) (result anyref)))
  (import "js" "caml_fetch_wasm_stream_read" (func $stream_read (param anyref) (param f64) (param funcref) (param anyref)))
  (import "js" "caml_fetch_wasm_stream_close" (func $stream_close (param anyref)))

  (type $done
    (func (param anyref) (param i32) (param anyref) (param anyref) (param anyref)))

  (type $timer_done (func (param anyref)))

  (type $chunk_done
    (func (param anyref) (param i32) (param anyref) (param anyref)))

  (elem declare func $done_string $done_bigstring $done_timer $done_head $chunk_string $chunk_bigstring $deliver)

  (func $js_string (param $s (ref eq)) (result anyref)
    (call $unwrap
      (call $caml_jsstring_of_string
        (local.get $s))))

  (func $request
    (param $meth (ref eq)) (param $url (ref eq)) (param $headers (ref eq)) (param $body (ref eq)) (param $timeout (ref eq)) (param $cb (ref eq)) (param $done (ref $done)) (param $stream i32) (result (ref eq))
    (local $hs (ref $block))
    (local $h (ref $block))
    (local $arr anyref)
    (local $i i32)
    (local $n i32)
    (local $js_body anyref)

    (local.set $hs
      (ref.cast (ref $block)
        (local.get $headers)))
    (local.set $arr
      (call $new_array))
    (local.set $n
      (array.len
        (local.get $hs)))
    (local.set $i
      (i32.const 1))
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

          (call $Double_val
            (local.get $timeout))
          (local.get $done)

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

  (func (export "caml_fetch_after")
    (param $seconds (ref eq)) (param $cb (ref eq)) (result (ref eq))
    (call $wrap
      (call $after
        (call $Double_val
          (local.get $seconds))
        (ref.func $done_timer)
        (local.get $cb))))

  (func (export "caml_fetch_cancel_timer")
    (param $timer (ref eq)) (result (ref eq))
    (call $cancel_timer
      (call $unwrap
        (local.get $timer)))
    (ref.i31
      (i32.const 0)))

  (func $done_head (type $done)
    (param $ctx anyref) (param $status i32) (param $headers anyref) (param $body anyref) (param $err anyref)
    (call $finish
      (local.get $ctx)
      (local.get $status)
      (local.get $headers)
      (ref.i31
        (i32.const 0))
      (local.get $err)))

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

  (func (export "caml_fetch_run_local_until") (param $_fd (ref eq)) (result (ref eq))
    (ref.i31
      (i32.const 0)))

  (func (export "caml_fetch_set_wake_fd") (param $_fd (ref eq)) (result (ref eq))
    (ref.i31
      (i32.const 0)))

  (func (export "caml_fetch_dispatch") (param $_unit (ref eq)) (result (ref eq))
    (ref.i31
      (i32.const 0)))

  (func (export "caml_fetch_use_background") (param $_unit (ref eq)) (result (ref eq))
    (ref.i31
      (i32.const 0))))
