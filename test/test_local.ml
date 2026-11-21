(* Native/bytecode, local mode (tokio runs on this thread, inside Fetch.run). *)
open Test_cases

exception Boom

let () = Test_server.start ~script:"server.js"

(* Runs a shared case to completion with an explicit Fetch.run. *)
let run_case f () =
  let finished = ref false in
  f (fun () -> finished := true);
  Fetch.run ();
  Alcotest.(check bool) "the case completed" true !finished;
  Alcotest.(check int) "nothing pending" 0 (Fetch.pending ())

let shared = List.map (fun (name, f) -> Alcotest.test_case name `Quick (run_case f)) Cases.all

let exn_from_run () =
  let second = ref false in
  Fetch.req (Cases.url "/delay/1") (fun _ -> raise Boom);
  Fetch.req (Cases.url "/delay/2") (fun _ -> second := true);
  Alcotest.check_raises "a callback's exception comes out of Fetch.run" Boom Fetch.run;
  Alcotest.(check bool) "the other request is still pending" false !second;
  Fetch.run ();
  Alcotest.(check bool) "the next Fetch.run completes it" true !second

let nested_run () =
  let raised = ref false in
  Fetch.req (Cases.url "/echo") (fun _ ->
    try Fetch.run () with Failure _ -> raised := true);
  Fetch.run ();
  Alcotest.(check bool) "Fetch.run from a callback raises Failure" true !raised

(* The delay counts from the call, not from when the loop starts. *)
let after_deadline () =
  let t0 = Unix.gettimeofday () in
  let fired = ref 0. in
  Fetch.after 0.2 (fun () -> fired := Unix.gettimeofday () -. t0);
  while Unix.gettimeofday () -. t0 < 0.5 do () done;
  Fetch.run ();
  Alcotest.(check bool) "fired as soon as the loop ran" true (!fired >= 0.5 && !fired < 0.6)

let after_nan () =
  Alcotest.check_raises "NaN is rejected" (Invalid_argument "Fetch.after: NaN") (fun () ->
    Fetch.after Float.nan ignore);
  Alcotest.(check int) "nothing pending" 0 (Fetch.pending ())

let () =
  Alcotest.run "fetch (local mode)"
    [
      ("cases", shared);
      ( "run",
        [
          Alcotest.test_case "exception from a callback" `Quick exn_from_run;
          Alcotest.test_case "Fetch.run from a callback" `Quick nested_run;
          Alcotest.test_case "Fetch.after: delay counted from the call" `Quick after_deadline;
          Alcotest.test_case "Fetch.after NaN" `Quick after_nan;
        ] );
    ]
