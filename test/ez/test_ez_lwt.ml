(* ez_api.req_lwt (EzReqLwt) with the fetch.ez_api_lwt engine. *)
open Lwt.Syntax
open Test_cases

let () = Test_server.start ~script:"../server.js"

let base () = EzAPI.BASE !Cases.base
let raw path = EzAPI.URL (Cases.url path)

let raw_get _ () =
  let* r = EzReqLwt.get (raw "/raw") in
  Alcotest.(check bool) "GET echoed" true
    (match r with Ok s -> Cases.contains s {|"method":"GET"|} | Error _ -> false);
  Lwt.return_unit

let raw_post _ () =
  let* r = EzReqLwt.post ~content:{|{"a":1}|} (raw "/raw") in
  Alcotest.(check bool) "POST echoed, JSON content-type by default" true
    (match r with
     | Ok s -> Cases.contains s {|"method":"POST"|} && Cases.contains s {|\"a\":1|} && Cases.contains s "application/json"
     | Error _ -> false);
  Lwt.return_unit

let errors _ () =
  let* r = EzReqLwt.get (raw "/status/404") in
  Alcotest.(check bool) "404 is Error (404, _)" true (match r with Error (404, Some _) -> true | _ -> false);
  let* r = EzReqLwt.get (EzAPI.URL "http://localhost:1/") in
  Alcotest.(check int) "connection refused is code -1" (-1) (match r with Error (c, _) -> c | Ok _ -> 0);
  Lwt.return_unit

let typed _ () =
  let* r = EzReqLwt.get0 (base ()) Echo.get in
  Alcotest.(check bool) "get0" true (match r with Ok { Echo.meth; url; _ } -> meth = "GET" && url = "/echo" | Error _ -> false);
  let* r = EzReqLwt.post0 ~input:[ "x"; "y" ] (base ()) Echo.post in
  Alcotest.(check bool) "post0" true
    (match r with Ok { Echo.meth; body; ct; _ } -> meth = "POST" && body = {|["x","y"]|} && ct = "application/json" | Error _ -> false);
  Lwt.return_unit

let concurrent _ () =
  let t0 = Unix.gettimeofday () in
  let* rs = Lwt.all (List.init 3 (fun _ -> EzReqLwt.get (raw "/delay/1"))) in
  Alcotest.(check bool) "3 responses" true (List.for_all Result.is_ok rs);
  Alcotest.(check bool) "concurrently" true (Unix.gettimeofday () -. t0 < 1.8);
  Lwt.return_unit

let () =
  Lwt_main.run
  @@ Alcotest_lwt.run "fetch.ez_api_lwt"
    [
      ( "EzReqLwt",
        [
          Alcotest_lwt.test_case "raw get" `Quick raw_get;
          Alcotest_lwt.test_case "raw post" `Quick raw_post;
          Alcotest_lwt.test_case "errors" `Quick errors;
          Alcotest_lwt.test_case "typed services" `Quick typed;
          Alcotest_lwt.test_case "concurrent requests" `Quick concurrent;
        ] );
    ]
