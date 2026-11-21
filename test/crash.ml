(* Main dies from an uncaught exception: the at-exit loop must NOT run.
   Expected: immediate "Fatal error: exception Failure", exit code 2,
   no callback output. *)
let () =
  Fetch.req (Test_cases.Cases.url "/delay/2") (fun _ -> print_endline "BUG: loop ran after crash");
  failwith "main crashed"
