(* Test cases shared by every backend and mode, written with callbacks: a case
   starts its requests and calls [k ()] once all its checks have passed. A
   failed check raises [Failure], from the callback where it happens.

   The test server (../server.js) is at [!base]: $FETCH_TEST_URL by default
   (or http://localhost:8765), set by Test_server.start in the Alcotest
   suites. *)

let base =
  ref
    (match Sys.getenv_opt "FETCH_TEST_URL" with
     | Some u -> u
     | None -> "http://localhost:8765")

let url path = !base ^ path
let fail fmt = Printf.ksprintf failwith fmt
let check name b = if not b then fail "check failed: %s" name

let ok = function
  | Ok r -> r
  | Error e -> fail "request failed: %s" e

let contains s sub =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

let string_of_bigstring b = String.init (Bigarray.Array1.dim b) (Bigarray.Array1.get b)

(* ---- Cases *)

let echo k =
  Fetch.req ~meth:`PUT ~headers:[ ("Content-Type", "text/plain") ] ~body:"hello" (url "/echo") (fun r ->
    let { Fetch.status; body; _ } = ok r in
    check "status 200" (status = 200);
    check "method, path and body echoed"
      (contains body {|"method":"PUT"|} && contains body {|"url":"/echo"|}
       && contains body {|"body":"hello"|});
    check "request header sent" (contains body {|"ct":"text/plain"|});
    k ())

let headers k =
  Fetch.req (url "/echo") (fun r ->
    let h = (ok r).Fetch.headers in
    check "Headers.get is case-insensitive"
      (Fetch.Headers.get h "Content-Type" = Some "application/json"
       && Fetch.Headers.get h "content-type" = Some "application/json");
    check "Headers.get of a missing header" (Fetch.Headers.get h "x-nope" = None);
    check "Headers.to_list has lowercase names"
      (List.mem_assoc "content-type" (Fetch.Headers.to_list h));
    check "Headers.get_all" (Fetch.Headers.get_all h "content-type" = [ "application/json" ]);
    k ())

let payload = String.init 300_000 (fun i -> Char.chr (i land 255))

(* the same request with a string body and a bigstring body *)
let bigstring k =
  Fetch.req ~meth:`POST ~body:payload (url "/echo") (fun rs ->
    let rs = (ok rs).Fetch.body in
    Fetch.req_bs ~meth:`POST ~body:payload (url "/echo") (fun rb ->
      let rb = (ok rb).Fetch.body in
      check "same length" (Bigarray.Array1.dim rb = String.length rs);
      check "same bytes" (string_of_bigstring rb = rs);
      (* a sub-array must keep the buffer alive on its own *)
      let sub = Bigarray.Array1.sub rb 10 20 in
      Gc.full_major ();
      Gc.full_major ();
      check "sub-array still valid after a GC" (string_of_bigstring sub = String.sub rs 10 20);
      k ()))

let status k =
  Fetch.req (url "/status/404") (fun r ->
    check "a 404 is a response, not an error" ((ok r).Fetch.status = 404);
    k ())

let refused k =
  Fetch.req "http://localhost:1/" (fun r ->
    check "connection refused is an Error" (Result.is_error r);
    k ())

let concurrent k =
  let t0 = Unix.gettimeofday () in
  let left = ref 3 in
  for _ = 1 to 3 do
    Fetch.req (url "/delay/1") (fun r ->
      ignore (ok r);
      decr left;
      if !left = 0 then begin
        check "3 requests of 1 s took less than 1.8 s" (Unix.gettimeofday () -. t0 < 1.8);
        k ()
      end)
  done

(* requests started from callbacks: the loop must keep running for them *)
let nested k =
  let log = Buffer.create 64 in
  let rec chain n =
    Printf.bprintf log "start%d " n;
    Fetch.req (url "/echo") (fun r ->
      ignore (ok r);
      Printf.bprintf log "done%d " n;
      if n < 3 then chain (n + 1)
      else begin
        check "nested requests ran in order"
          (Buffer.contents log = "start1 done1 start2 done2 start3 done3 ");
        let left = ref 3 in
        for _ = 1 to 3 do
          Fetch.req (url "/echo") (fun r ->
            ignore (ok r);
            decr left;
            if !left = 0 then k ())
        done
      end)
  in
  chain 1

(* ?timeout: the slow request is aborted with Error "timeout", soon after
   its timeout; a timeout longer than the request changes nothing. *)
let timeout k =
  let t0 = Unix.gettimeofday () in
  Fetch.req ~timeout:0.3 (url "/delay/2") (fun r ->
    (match r with
     | Error "timeout" -> ()
     | Error e -> fail "expected Error \"timeout\", got Error %S" e
     | Ok _ -> fail "expected Error \"timeout\", got a response");
    check "aborted after about 0.3 s" (Unix.gettimeofday () -. t0 < 1.);
    Fetch.req_bs ~timeout:5. (url "/echo") (fun r ->
      check "a timeout longer than the request" ((ok r).Fetch.status = 200);
      k ()))

(* Fetch.after: timers fire in order of their deadlines, not of their
   creation, alongside requests; a timer started from a callback keeps the
   loop running. *)
let timers k =
  let t0 = Unix.gettimeofday () in
  let log = Buffer.create 64 in
  let note s = Buffer.add_string log s in
  Fetch.req (url "/delay/1") (fun r ->
    ignore (ok r);
    note "req ";
    Fetch.after 0.1 (fun () ->
      note "nested ";
      check "fired in deadline order" (Buffer.contents log = "now 0.1 0.2 req nested ");
      (* setTimeout may fire up to a millisecond early *)
      check "1 s request, then 0.1 s timer" (Unix.gettimeofday () -. t0 >= 1.09);
      k ()));
  Fetch.after 0.2 (fun () -> note "0.2 ");
  Fetch.after 0.1 (fun () -> note "0.1 ");
  Fetch.after (-1.) (fun () -> note "now ")

(* Fetch.cancel: a cancelled timer never fires, and no longer keeps the
   loop running (if it did, the 1-hour one would hang the test). *)
let cancel k =
  let never () = fail "a cancelled timer fired" in
  let long = Fetch.timer 3600. never in
  (* cancelled before the loop even runs, twice *)
  let short = Fetch.timer 0.05 never in
  Fetch.cancel short;
  Fetch.cancel short;
  (* cancelling a timer from its own callback does nothing *)
  let self = ref None in
  self := Some (Fetch.timer 0.05 (fun () -> Option.iter Fetch.cancel !self));
  Fetch.after 0.1 (fun () ->
    Fetch.cancel long;
    (* a timer that has fired cannot be cancelled any more *)
    Option.iter Fetch.cancel !self;
    k ())

(* ---- Streams *)

(* Reads [s] to its end with [read] ([Fetch.read] or [Fetch.read_bs], [conv]
   turning a chunk into a string), then calls [k] with the body and the time
   at which the first chunk arrived. *)
let read_all read conv s k =
  let buf = Buffer.create 64 in
  let first = ref None in
  let rec loop () =
    read s (function
      | Ok (Some c) ->
        if !first = None then first := Some (Unix.gettimeofday ());
        Buffer.add_string buf (conv c);
        loop ()
      | Ok None -> k (Buffer.contents buf) (Option.get !first)
      | Error e -> fail "read failed: %s" e)
  in
  loop ()

let chunks n = String.concat "" (List.init n (Printf.sprintf "chunk %d\n"))

(* the body arrives chunk by chunk, not all at the end *)
let stream k =
  let t0 = Unix.gettimeofday () in
  Fetch.req_stream (url "/stream/5/100") (fun r ->
    let { Fetch.status; headers; body = s } = ok r in
    check "status 200" (status = 200);
    check "headers" (Fetch.Headers.get headers "content-type" = Some "text/plain");
    check "headers before the body (0.4 s)" (Unix.gettimeofday () -. t0 < 0.3);
    read_all (fun s k -> Fetch.read s k) Fun.id s (fun body first ->
      check "whole body" (body = chunks 5);
      check "first chunk before the end" (first -. t0 < 0.3);
      check "the end took the 5 chunks' time" (Unix.gettimeofday () -. t0 >= 0.35);
      Fetch.read s (function
        | Ok None -> k ()
        | _ -> fail "a read after the end should give Ok None")))

let stream_bigstring k =
  Fetch.req_stream (url "/stream/3/10") (fun r ->
    read_all (fun s k -> Fetch.read_bs s k) string_of_bigstring (ok r).Fetch.body (fun body _ ->
      check "whole body, as bigstrings" (body = chunks 3);
      k ()))

let expect_error what e = function
  | Error e' when e' = e -> ()
  | Error e' -> fail "%s: expected Error %S, got Error %S" what e e'
  | Ok _ -> fail "%s: expected Error %S, got Ok" what e

(* ?timeout of req_stream: the headers; ?timeout of read: the next chunk *)
let stream_timeouts k =
  let t0 = Unix.gettimeofday () in
  Fetch.req_stream ~timeout:0.3 (url "/delay/2") (fun r ->
    expect_error "headers timeout" "timeout" r;
    check "headers timeout after about 0.3 s" (Unix.gettimeofday () -. t0 < 1.);
    Fetch.req_stream ~timeout:5. (url "/stall") (fun r ->
      let s = (ok r).Fetch.body in
      Fetch.read s (function
        | Ok (Some "first\n") ->
          let t1 = Unix.gettimeofday () in
          Fetch.read ~timeout:0.3 s (fun r ->
            expect_error "read timeout" "timeout" r;
            check "read timeout after about 0.3 s" (Unix.gettimeofday () -. t1 < 1.);
            Fetch.read s (fun r ->
              expect_error "read after a timeout" "closed" r;
              k ()))
        | _ -> fail "expected the first chunk")))

(* closing a stream that never ends: the pending read fails, nothing is left
   pending (the case would hang otherwise) *)
let stream_close k =
  Fetch.req_stream (url "/stall") (fun r ->
    let s = (ok r).Fetch.body in
    Fetch.read s (fun _ ->
      Fetch.read s (fun r ->
        expect_error "read pending during close" "closed" r;
        Fetch.close s;
        Fetch.read_bs s (fun r ->
          expect_error "read after close" "closed" r;
          k ()));
      (match Fetch.read s ignore with
       | () -> fail "a second concurrent read should be rejected"
       | exception Invalid_argument _ -> ());
      Fetch.after 0.2 (fun () -> Fetch.close s)))

let all =
  [
    ("echo", echo);
    ("headers", headers);
    ("bigstring body", bigstring);
    ("non-2xx status", status);
    ("connection refused", refused);
    ("concurrent requests", concurrent);
    ("nested requests", nested);
    ("timers", timers);
    ("timeout", timeout);
    ("cancel", cancel);
    ("stream", stream);
    ("stream, bigstring chunks", stream_bigstring);
    ("stream timeouts", stream_timeouts);
    ("stream close", stream_close);
  ]
