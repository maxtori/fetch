(* An exception raised by a callback must come out of [Fetch.run]
   (native/bytecode) without unwinding through Rust frames. A second [run]
   then finishes the request still in flight. *)
exception Boom
let () =
  Fetch.req (Test_cases.Cases.url "/delay/1") (fun _ -> raise Boom);
  Fetch.req (Test_cases.Cases.url "/delay/2") (fun _ -> print_endline "second request done");
  (try Fetch.run (); print_endline "run returned (JS: expected, Boom kills the program later)"
   with Boom -> print_endline "caught Boom from run: OK");
  Fetch.run ()
