(* Direct style (effects). Same source for native, bytecode and JavaScript:
     ./_build/default/example/direct.exe URL...
     ./_build/default/example/direct.bc.exe URL...
     node _build/default/example/direct.bc.js URL... *)

let t0 = Unix.gettimeofday ()
let log fmt = Printf.printf ("[%5.2fs] " ^^ fmt ^^ "\n%!") (Unix.gettimeofday () -. t0)

let show url = function
  | Ok { Fetch.status; body; headers } ->
    log "%s -> %d (%d bytes, content-type: %s)" url status (String.length body)
      (Option.value ~default:"?" (Fetch.Headers.get headers "content-type"))
  | Error e -> log "%s -> error: %s" url e

let () =
  let urls =
    match List.tl (Array.to_list Sys.argv) with
    | [] -> [ "https://example.com"; "https://httpbin.org/delay/1" ]
    | l -> l
  in
  Fetch_direct.spawn @@ fun () ->
  (* 1. Plain callback style *)
  Fetch.req (List.hd urls) (fun r -> log "callback:"; show (List.hd urls) r);

  (* 2. Direct style, all URLs concurrently *)
  let results = Fetch_direct.all (List.map (fun u () -> (u, Fetch_direct.req u)) urls) in
  log "all %d done:" (List.length results);
  List.iter (fun (u, r) -> show u r) results;

  (* 3. Sequential, with a body *)
  let r =
    Fetch_direct.req ~meth:`POST
      ~headers:[ ("content-type", "text/plain") ]
      ~body:"hello from OCaml" (List.hd urls)
  in
  log "POST:";
  show (List.hd urls) r
