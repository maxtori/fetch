(* Runs the shared cases one after the other, from the event loop: the
   at-exit loop on native/bytecode (in background mode with FETCH_BG=1), the
   JS event loop on JS/Wasm. Prints one line per case; a failed check kills
   the program with "Fatal error: exception Failure(...)". *)
open Test_cases

let () =
  if Sys.getenv_opt "FETCH_BG" = Some "1" then Fetch.use_external_loop ();
  let rec go = function
    | [] -> print_endline "all cases passed"
    | (name, f) :: rest ->
      f (fun () ->
        Printf.printf "ok %s\n%!" name;
        go rest)
  in
  go Cases.all
