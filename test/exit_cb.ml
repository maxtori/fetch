(* [exit] from a callback during the at-exit loop: exits right away with that
   code (3); the other request is abandoned. *)
let () =
  Fetch.req (Test_cases.Cases.url "/delay/1") (fun _ -> print_endline "exiting with 3"; exit 3);
  Fetch.req (Test_cases.Cases.url "/delay/2") (fun _ -> print_endline "BUG: should have exited")
