(* Starts the test server (node server.js) on a free port for this test
   process, and points the shared cases at it. The server exits when this
   process does (its stdin, a pipe from us, is closed). *)

let start ~script =
  let ic, oc =
    Unix.open_process_args "node" [| "node"; script; "0"; "--exit-with-stdin" |]
  in
  let line = try input_line ic with End_of_file -> failwith "the test server did not start" in
  match String.split_on_char ' ' line with
  | [ "listening"; port ] ->
    Test_cases.Cases.base := "http://localhost:" ^ port;
    at_exit (fun () -> try Unix.kill (Unix.process_pid (ic, oc)) Sys.sigterm with _ -> ())
  | _ -> failwith ("unexpected output from the test server: " ^ line)
