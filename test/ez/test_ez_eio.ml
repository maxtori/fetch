(* ez_api.req_eio (EzReqEio) with the fetch.ez_api_eio engine. *)
open Test_cases

let () = Test_server.start ~script:"../server.js"

let base () = EzAPI.BASE !Cases.base
let raw path = EzAPI.URL (Cases.url path)

(* ~net and ~sw are required by the interface (and ignored by the engine) *)
let with_eio f () = Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw -> f ~net:(Eio.Stdenv.net env) ~sw

let raw_get ~net ~sw =
  let code, body, headers = EzReqEio.get ~net ~sw (raw "/raw") in
  Alcotest.(check int) "status" 200 code;
  Alcotest.(check bool) "GET echoed" true (Cases.contains body {|"method":"GET"|});
  Alcotest.(check (option string)) "response headers" (Some "application/json")
    (List.assoc_opt "content-type" headers)

let raw_post ~net ~sw =
  let code, body, _ =
    EzReqEio.post ~content_type:"application/json" ~content:{|{"a":1}|} ~net ~sw (raw "/raw")
  in
  Alcotest.(check int) "status" 200 code;
  Alcotest.(check bool) "POST echoed" true
    (Cases.contains body {|"method":"POST"|} && Cases.contains body {|\"a\":1|} && Cases.contains body "application/json")

let errors ~net ~sw =
  let code, _, _ = EzReqEio.get ~net ~sw (raw "/status/404") in
  Alcotest.(check int) "404" 404 code;
  let code, _, _ = EzReqEio.get ~net ~sw (EzAPI.URL "http://localhost:1/") in
  Alcotest.(check int) "connection refused is code -1" (-1) code;
  Alcotest.(check bool) "typed call on a 404 is an error" true
    (match EzReqEio.get0 ~net ~sw (EzAPI.BASE (Cases.url "/status/404")) Echo.get with
     | Error (404, _) -> true
     | _ -> false)

let typed ~net ~sw =
  Alcotest.(check bool) "get0" true
    (match EzReqEio.get0 ~net ~sw (base ()) Echo.get with
     | Ok { Echo.meth; url; _ } -> meth = "GET" && url = "/echo"
     | Error _ -> false);
  Alcotest.(check bool) "post0" true
    (match EzReqEio.post0 ~net ~sw ~input:[ "x"; "y" ] (base ()) Echo.post with
     | Ok { Echo.meth; body; ct; _ } -> meth = "POST" && body = {|["x","y"]|} && ct = "application/json"
     | Error _ -> false)

let concurrent ~net ~sw =
  let t0 = Unix.gettimeofday () in
  let rs = Eio.Fiber.List.map (fun () -> EzReqEio.get ~net ~sw (raw "/delay/1")) [ (); (); () ] in
  Alcotest.(check bool) "3 responses" true (List.for_all (fun (c, _, _) -> c = 200) rs);
  Alcotest.(check bool) "concurrently" true (Unix.gettimeofday () -. t0 < 1.8)

let () =
  Alcotest.run "fetch.ez_api_eio"
    [
      ( "EzReqEio",
        [
          Alcotest.test_case "raw get" `Quick (with_eio raw_get);
          Alcotest.test_case "raw post" `Quick (with_eio raw_post);
          Alcotest.test_case "errors" `Quick (with_eio errors);
          Alcotest.test_case "typed services" `Quick (with_eio typed);
          Alcotest.test_case "concurrent requests" `Quick (with_eio concurrent);
        ] );
    ]
