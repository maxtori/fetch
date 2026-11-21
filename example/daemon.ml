(* A daemon polling URLs every few seconds, with the callback API only.
     ./_build/default/example/daemon.exe [-every SECONDS] [-n ROUNDS] URL...
     node _build/default/example/daemon.bc.js [-every SECONDS] [-n ROUNDS] URL...

   Each round starts every request concurrently; once all have answered, a
   timer (Fetch.after) starts the next round. No Fetch.run and no blocking
   sleep: as in JS, the main program only starts the first round, and the
   event loop (at exit on native, the host's on JS/Wasm) runs everything,
   until there is nothing left to do (after [-n ROUNDS] rounds) or Ctrl-C. *)

let t0 = Unix.gettimeofday ()
let log fmt = Printf.printf ("[%7.2fs] " ^^ fmt ^^ "\n%!") (Unix.gettimeofday () -. t0)

(* One round: every URL concurrently; [k ()] once all have answered. *)
let round n urls k =
  let ok = ref 0 and left = ref (List.length urls) in
  List.iter (fun url ->
    let start = Unix.gettimeofday () in
    Fetch.req url (fun r ->
      let ms = (Unix.gettimeofday () -. start) *. 1000. in
      (match r with
       | Ok { Fetch.status; body; _ } ->
         if status >= 200 && status < 300 then incr ok;
         log "#%d %s -> %d (%d bytes, %.0f ms)" n url status (String.length body) ms
       | Error e -> log "#%d %s -> error: %s (%.0f ms)" n url e ms);
      decr left;
      if !left = 0 then begin
        log "#%d done: %d/%d ok" n !ok (List.length urls);
        k ()
      end))
    urls

let () =
  let every = ref 5. and rounds = ref 0 and urls = ref [] in
  Arg.parse
    [
      ("-every", Arg.Set_float every, "SECONDS  time between the starts of two rounds (default 5)");
      ("-n", Arg.Set_int rounds, "ROUNDS  stop after this many rounds (default 0: never)");
    ]
    (fun u -> urls := u :: !urls)
    "daemon [-every SECONDS] [-n ROUNDS] URL...";
  let urls = if !urls = [] then [ "https://example.com" ] else List.rev !urls in
  log "polling %d URL(s) every %gs" (List.length urls) !every;
  (* Rounds start every [every] seconds; a round longer than that is followed
     by the next one at once (Fetch.after with a negative delay). *)
  let rec tick n =
    let start = Unix.gettimeofday () in
    round n urls (fun () ->
      if n = !rounds then log "stopped"
      else Fetch.after (start +. !every -. Unix.gettimeofday ()) (fun () -> tick (n + 1)))
  in
  tick 1
