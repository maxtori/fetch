(* fetch.direct (OCaml 5): fibers on top of the callbacks, local mode. *)
open Test_cases

exception Boom

let () = Test_server.start ~script:"server.js"

let direct_sequential () =
  let log = ref [] in
  Fetch_direct.spawn (fun () ->
    let a = Fetch_direct.req (Cases.url "/echo") in
    log := "a" :: !log;
    let b = Fetch_direct.req_bs (Cases.url "/echo") in
    log := "b" :: !log;
    Cases.check "both succeeded" (Result.is_ok a && Result.is_ok b));
  Fetch.run ();
  Alcotest.(check (list string)) "requests ran one after the other" [ "a"; "b" ] (List.rev !log)

let direct_all () =
  let t0 = Unix.gettimeofday () in
  let results = ref [] in
  Fetch_direct.spawn (fun () ->
    results :=
      Fetch_direct.all
        (List.map (fun p () -> Fetch_direct.req (Cases.url p)) [ "/delay/1"; "/echo"; "/delay/1" ]));
  Fetch.run ();
  Alcotest.(check int) "3 results" 3 (List.length !results);
  Alcotest.(check bool) "in order" true
    (match List.map (fun r -> (Cases.ok r).Fetch.body) !results with
     | [ a; b; c ] -> Cases.contains a "/delay/1" && Cases.contains b "/echo" && Cases.contains c "/delay/1"
     | _ -> false);
  Alcotest.(check bool) "concurrently" true (Unix.gettimeofday () -. t0 < 1.8)

let direct_exn () =
  Fetch_direct.spawn (fun () ->
    Fetch_direct.fork (fun () ->
      ignore (Fetch_direct.req (Cases.url "/delay/1"));
      raise Boom);
    ignore (Fetch_direct.req (Cases.url "/delay/2")));
  Alcotest.check_raises "a fiber's exception comes out of Fetch.run" Boom Fetch.run;
  Fetch.run ()

(* sleeping fibers wake up by deadline, concurrently *)
let direct_sleep () =
  let t0 = Unix.gettimeofday () in
  let log = ref [] in
  let fiber name d () = Fetch_direct.sleep d; log := name :: !log in
  Fetch_direct.spawn (fun () ->
    ignore (Fetch_direct.all [ fiber "0.3" 0.3; fiber "0.1" 0.1; fiber "0.2" 0.2 ]));
  Fetch.run ();
  Alcotest.(check (list string)) "woke up by deadline" [ "0.1"; "0.2"; "0.3" ] (List.rev !log);
  Alcotest.(check bool) "concurrently" true (Unix.gettimeofday () -. t0 < 0.5)

(* ---- race *)

(* Runs [f] in a fiber, then the loop until nothing is pending. Returns
   [f]'s result, and how long the whole thing took. *)
let in_fiber f =
  let t0 = Unix.gettimeofday () in
  let r = ref None in
  Fetch_direct.spawn (fun () -> r := Some (f ()));
  Fetch.run ();
  Alcotest.(check int) "nothing pending" 0 (Fetch.pending ());
  (Option.get !r, Unix.gettimeofday () -. t0)

let branch d v () = Fetch_direct.sleep d; v

let race_first () =
  let v, t = in_fiber (fun () -> Fetch_direct.race [ branch 10. "slow"; branch 0.1 "fast" ]) in
  Alcotest.(check string) "the first to finish wins" "fast" v;
  (* the loser's timer is cancelled: nothing keeps the loop running *)
  Alcotest.(check bool) "the loser does not keep the loop running" true (t < 0.5)

let race_finalizer () =
  let finalized = ref false in
  let loser () =
    Fun.protect ~finally:(fun () -> finalized := true) (fun () -> Fetch_direct.sleep 10.; "slow")
  in
  let v, t = in_fiber (fun () -> Fetch_direct.race [ loser; branch 0.1 "fast" ]) in
  Alcotest.(check string) "winner" "fast" v;
  Alcotest.(check bool) "the loser's finalizer ran" true !finalized;
  Alcotest.(check bool) "quickly" true (t < 0.5)

let race_exn () =
  let r, t =
    in_fiber (fun () ->
      match Fetch_direct.race [ branch 10. (); (fun () -> Fetch_direct.sleep 0.1; raise Boom) ] with
      | () -> "returned"
      | exception Boom -> "raised")
  in
  Alcotest.(check string) "the first exception is raised" "raised" r;
  Alcotest.(check bool) "the other branch is cancelled" true (t < 0.5)

(* cancelling a branch cancels the races and fibers started in it *)
let race_nested () =
  let forked_done = ref false in
  let loser () =
    Fetch_direct.fork (fun () -> Fetch_direct.sleep 10.; forked_done := true);
    Fetch_direct.race [ branch 10. "a"; branch 20. "b" ]
  in
  let v, t = in_fiber (fun () -> Fetch_direct.race [ loser; branch 0.1 "fast" ]) in
  Alcotest.(check string) "winner" "fast" v;
  Alcotest.(check bool) "the fiber forked by the loser was cancelled" false !forked_done;
  Alcotest.(check bool) "quickly" true (t < 0.5)

(* a branch finishing without suspending wins; the next ones never start *)
let race_sync () =
  let started = ref false in
  let v, _ =
    in_fiber (fun () ->
      Fetch_direct.race [ (fun () -> "now"); (fun () -> started := true; "later") ])
  in
  Alcotest.(check string) "winner" "now" v;
  Alcotest.(check bool) "the second branch did not start" false !started

(* a request cannot be aborted: the race returns, the request carries on *)
let race_request () =
  let t0 = Unix.gettimeofday () in
  let at = ref 0. in
  let v, t =
    in_fiber (fun () ->
      let v =
        Fetch_direct.race
          [
            (fun () -> ignore (Fetch_direct.req (Cases.url "/delay/1")); "response");
            branch 0.1 "timeout";
          ]
      in
      at := Unix.gettimeofday () -. t0;
      v)
  in
  Alcotest.(check string) "the timeout wins" "timeout" v;
  Alcotest.(check bool) "race returned at once" true (!at < 0.5);
  Alcotest.(check bool) "the loop waited for the request" true (t >= 0.9)

(* ---- streams *)

let stream_open path =
  match Fetch_direct.req_stream (Cases.url path) with
  | Ok r -> r.Fetch.body
  | Error e -> Alcotest.fail e

let direct_stream () =
  let body, _ =
    in_fiber (fun () ->
      let s = stream_open "/stream/3/50" in
      let buf = Buffer.create 64 in
      let rec loop () =
        match Fetch_direct.read s with
        | Ok (Some c) -> Buffer.add_string buf c; loop ()
        | Ok None -> Buffer.contents buf
        | Error e -> Alcotest.fail e
      in
      loop ())
  in
  Alcotest.(check string) "body" (Cases.chunks 3) body

(* a read that loses a race closes its stream: nothing is left pending
   (in_fiber would hang on the stalled stream otherwise) *)
let race_closes_stream () =
  let after, t =
    in_fiber (fun () ->
      let s = stream_open "/stall" in
      ignore (Fetch_direct.read s);
      let r =
        Fetch_direct.race
          [ (fun () -> ignore (Fetch_direct.read s); "read"); (fun () -> Fetch_direct.sleep 0.2; "sleep") ]
      in
      Alcotest.(check string) "the sleep wins" "sleep" r;
      Fetch_direct.read s)
  in
  Alcotest.(check bool) "the stream was closed" true (after = Error "closed");
  Alcotest.(check bool) "quickly" true (t < 1.)

let race_empty () =
  Alcotest.check_raises "empty list" (Invalid_argument "Fetch_direct.race: empty list") (fun () ->
    ignore (in_fiber (fun () -> Fetch_direct.race [])))

let () =
  Alcotest.run "fetch.direct"
    [
      ( "direct",
        [
          Alcotest.test_case "sequential requests" `Quick direct_sequential;
          Alcotest.test_case "all" `Quick direct_all;
          Alcotest.test_case "exception from a fiber" `Quick direct_exn;
          Alcotest.test_case "sleep" `Quick direct_sleep;
        ] );
      ( "race",
        [
          Alcotest.test_case "first to finish wins" `Quick race_first;
          Alcotest.test_case "losers run their finalizers" `Quick race_finalizer;
          Alcotest.test_case "exception" `Quick race_exn;
          Alcotest.test_case "nested races and forks are cancelled" `Quick race_nested;
          Alcotest.test_case "branch finishing at once" `Quick race_sync;
          Alcotest.test_case "requests are not aborted" `Quick race_request;
          Alcotest.test_case "empty list" `Quick race_empty;
        ] );
      ( "streams",
        [
          Alcotest.test_case "read to the end" `Quick direct_stream;
          Alcotest.test_case "a read losing a race closes the stream" `Quick race_closes_stream;
        ] );
    ]
