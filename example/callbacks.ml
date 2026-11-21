(* Callback style only: no effects, so no --effects=cps on JS.
     ./_build/default/example/callbacks.exe URL...
     node _build/default/example/callbacks.bc.js URL... *)

let t0 = Unix.gettimeofday ()
let log fmt = Printf.printf ("[%5.2fs] " ^^ fmt ^^ "\n%!") (Unix.gettimeofday () -. t0)

let show url = function
  | Ok { Fetch.status; body; _ } ->
    log "%s -> %d (%d bytes)" url status (String.length body)
  | Error e -> log "%s -> error: %s" url e

let () =
  let urls =
    match List.tl (Array.to_list Sys.argv) with
    | [] -> [ "https://example.com"; "https://httpbin.org/delay/1" ]
    | l -> l
  in
  (* All URLs concurrently; when the last one is done, POST to the first. *)
  let remaining = ref (List.length urls) in
  List.iter
    (fun u ->
       Fetch.req u (fun r ->
         show u r;
         decr remaining;
         if !remaining = 0 then
           Fetch.req ~meth:`POST ~body:"hello from OCaml" (List.hd urls)
             (fun r -> log "POST:"; show (List.hd urls) r)))
    urls
(* No [Fetch.run] needed: the loop runs when the program is done. *)
