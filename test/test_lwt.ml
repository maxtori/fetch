(* fetch.lwt: responses delivered by the Lwt loop (background mode). *)
open Lwt.Syntax
open Test_cases

let () = Test_server.start ~script:"server.js"

let timeout name p =
  Lwt.pick [ p; (let* () = Lwt_unix.sleep 10. in Alcotest.failf "%s: timed out" name) ]

(* An exception raised by a callback comes out of the pump (Lwt.async), so it
   reaches Lwt.async_exception_hook: fail the running case with it. *)
let current : unit Lwt.u option ref = ref None

let () =
  Lwt.async_exception_hook :=
    fun e ->
      match !current with
      | Some r -> current := None; Lwt.wakeup_later_exn r e
      | None -> raise e

(* Runs a shared case (plain Fetch.req) under the Lwt loop. *)
let run_case name f _switch () =
  let p, r = Lwt.wait () in
  current := Some r;
  f (fun () -> current := None; Lwt.wakeup_later r ());
  Fetch_lwt.watch ();
  timeout name p

let concurrent_loop_not_blocked _switch () =
  let ticks = ref 0 in
  let stop = ref false in
  let rec ticker () =
    if !stop then Lwt.return_unit
    else let* () = Lwt_unix.sleep 0.05 in incr ticks; ticker ()
  in
  Lwt.async ticker;
  let t0 = Unix.gettimeofday () in
  let* rs = Lwt.all (List.init 3 (fun _ -> Fetch_lwt.req (Cases.url "/delay/1"))) in
  stop := true;
  Alcotest.(check bool) "3 responses" true (List.for_all Result.is_ok rs);
  Alcotest.(check bool) "concurrently" true (Unix.gettimeofday () -. t0 < 1.8);
  Alcotest.(check bool) "the Lwt loop kept running" true (!ticks >= 10);
  Alcotest.(check int) "nothing pending" 0 (Fetch.pending ());
  Lwt.return_unit

(* the pump stops when nothing is pending: a new request must restart it *)
let later_request _switch () =
  let* () = Lwt_unix.sleep 0.1 in
  let* r = Fetch_lwt.req (Cases.url "/echo") in
  Alcotest.(check bool) "a later request completes" true (Result.is_ok r);
  let* r = Fetch_lwt.req_bs (Cases.url "/echo") in
  Alcotest.(check bool) "req_bs" true (Result.is_ok r);
  Lwt.return_unit

let stream _switch () =
  let* r = Fetch_lwt.req_stream (Cases.url "/stream/3/50") in
  let s = match r with Ok r -> r.Fetch.body | Error e -> Alcotest.fail e in
  let buf = Buffer.create 64 in
  let rec loop () =
    let* c = Fetch_lwt.read_bs s in
    match c with
    | Ok (Some c) -> Buffer.add_string buf (Cases.string_of_bigstring c); loop ()
    | Ok None -> Lwt.return_unit
    | Error e -> Alcotest.fail e
  in
  let* () = loop () in
  Alcotest.(check string) "body" (Cases.chunks 3) (Buffer.contents buf);
  Lwt.return_unit

let () =
  Lwt_main.run
  @@ Alcotest_lwt.run "fetch.lwt"
    [
      ( "cases",
        List.map (fun (n, f) -> Alcotest_lwt.test_case n `Quick (run_case n f)) Cases.all );
      ( "lwt",
        [
          Alcotest_lwt.test_case "concurrent, loop not blocked" `Quick concurrent_loop_not_blocked;
          Alcotest_lwt.test_case "a later request restarts the pump" `Quick later_request;
          Alcotest_lwt.test_case "stream" `Quick stream;
        ] );
    ]
