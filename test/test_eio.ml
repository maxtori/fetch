(* fetch.eio: responses delivered by the Eio loop (background mode), with the
   default Eio backend and with the POSIX one. *)
open Test_cases

let () = Test_server.start ~script:"server.js"

let concurrent_loop_not_blocked () =
  let ticks = ref 0 in
  let t0 = Unix.gettimeofday () in
  let rs =
    Eio.Fiber.first
      (fun () ->
         let rec ticker () = Eio_unix.sleep 0.05; incr ticks; ticker () in
         ticker ())
      (fun () -> Eio.Fiber.List.map (fun p -> Fetch_eio.req (Cases.url p)) [ "/delay/1"; "/delay/1"; "/delay/1" ])
  in
  Alcotest.(check bool) "3 responses" true (List.for_all Result.is_ok rs);
  Alcotest.(check bool) "concurrently" true (Unix.gettimeofday () -. t0 < 1.8);
  Alcotest.(check bool) "the Eio loop kept running" true (!ticks >= 10);
  Alcotest.(check int) "nothing pending" 0 (Fetch.pending ())

let sequential () =
  let a = Fetch_eio.req (Cases.url "/echo") in
  let b = Fetch_eio.req_bs ~meth:`POST ~body:"x" (Cases.url "/echo") in
  Alcotest.(check bool) "both succeed" true (Result.is_ok a && Result.is_ok b);
  Alcotest.(check bool) "an error is an Error" true (Result.is_error (Fetch_eio.req "http://localhost:1/"))

(* only the calling fiber waits: another fiber's request completes first *)
let other_fibers () =
  let order = ref [] in
  Eio.Fiber.both
    (fun () -> ignore (Fetch_eio.req (Cases.url "/delay/1")); order := "slow" :: !order)
    (fun () -> ignore (Fetch_eio.req (Cases.url "/echo")); order := "fast" :: !order);
  Alcotest.(check (list string)) "completion order" [ "fast"; "slow" ] (List.rev !order)

let stream () =
  match Fetch_eio.req_stream (Cases.url "/stream/3/50") with
  | Error e -> Alcotest.fail e
  | Ok { Fetch.body = s; _ } ->
    let buf = Buffer.create 64 in
    let rec loop () =
      match Fetch_eio.read s with
      | Ok (Some c) -> Buffer.add_string buf c; loop ()
      | Ok None -> ()
      | Error e -> Alcotest.fail e
    in
    loop ();
    Alcotest.(check string) "body" (Cases.chunks 3) (Buffer.contents buf)

let tests run =
  List.map
    (fun (name, f) -> Alcotest.test_case name `Quick (fun () -> run (fun _env -> f ())))
    [
      ("concurrent, loop not blocked", concurrent_loop_not_blocked);
      ("sequential requests", sequential);
      ("only the calling fiber waits", other_fibers);
      ("stream", stream);
    ]

let () =
  Alcotest.run "fetch.eio"
    [ ("default backend", tests Eio_main.run); ("posix backend", tests Eio_posix.run) ]
