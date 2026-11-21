(* An exception in a fiber resumed by the event loop must come out of an
   explicit [Fetch.run]. *)
exception Boom
let () =
  Fetch_direct.spawn (fun () ->
    Fetch_direct.fork (fun () ->
      ignore (Fetch_direct.req (Test_cases.Cases.url "/delay/1"));
      raise Boom);
    ignore (Fetch_direct.req (Test_cases.Cases.url "/delay/2"));
    print_endline "main fiber finished (native: resumed by the loop at exit)");
  try Fetch.run (); print_endline "run returned (JS: expected, Boom kills the program later)"
  with Boom -> print_endline "caught Boom from run: OK"
