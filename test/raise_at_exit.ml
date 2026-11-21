(* A callback raises during the at-exit loop: the program dies with that
   exception (exit code 2), the loop is not restarted, and output buffered
   before the crash is still flushed. *)
exception Boom
let () =
  print_string "buffered (not flushed) output\n";
  Fetch.req (Test_cases.Cases.url "/delay/1") (fun _ -> print_string "callback 1 raising Boom\n"; raise Boom);
  Fetch.req (Test_cases.Cases.url "/delay/2") (fun _ -> print_endline "BUG: loop restarted")
