(* Native/bytecode, background mode (tokio on its own thread, responses
   delivered through Fetch.fd / Fetch.dispatch), as used by fetch.lwt and
   fetch.eio. *)
open Test_cases

exception Boom

let () = Fetch.use_external_loop ()
let () = Test_server.start ~script:"server.js"

(* Runs a shared case with Fetch.run, which also handles background mode. *)
let run_case f () =
  let finished = ref false in
  f (fun () -> finished := true);
  Fetch.run ();
  Alcotest.(check bool) "the case completed" true !finished;
  Alcotest.(check int) "nothing pending" 0 (Fetch.pending ())

(* Runs a shared case from a Unix.select loop on Fetch.fd, like any event
   loop would. *)
let select_case f () =
  let finished = ref false in
  f (fun () -> finished := true);
  let fd = Option.get (Fetch.fd ()) in
  while Fetch.pending () > 0 do
    ignore (Unix.select [ fd ] [] [] (-1.));
    Fetch.dispatch ()
  done;
  Alcotest.(check bool) "the case completed" true !finished

let exn_from_run () =
  let second = ref false in
  Fetch.req (Cases.url "/delay/1") (fun _ -> raise Boom);
  Fetch.req (Cases.url "/delay/2") (fun _ -> second := true);
  Alcotest.check_raises "a callback's exception comes out of Fetch.run" Boom Fetch.run;
  Fetch.run ();
  Alcotest.(check bool) "the next Fetch.run completes the other request" true !second

let () =
  Alcotest.run "fetch (background mode)"
    [
      ("cases, Fetch.run", List.map (fun (n, f) -> Alcotest.test_case n `Quick (run_case f)) Cases.all);
      ("cases, select loop", List.map (fun (n, f) -> Alcotest.test_case n `Quick (select_case f)) Cases.all);
      ("run", [ Alcotest.test_case "exception from a callback" `Quick exn_from_run ]);
    ]
