(* Requests must run in the background, dispatched from the Eio loop. Done
   when this module is initialised, i.e. before the program's first request. *)
let () = Fetch.use_external_loop ()

(* Each waiting fiber races its own result against pumping the wakeup fd:
   whichever fiber sees the fd readable dispatches every ready response
   (resolving other fibers' promises too). A fiber stops pumping as soon as
   its own result has arrived. No switch or background fiber needed. *)

let await start =
  let p, r = Eio.Promise.create () in
  start (Eio.Promise.resolve r);
  match Fetch.fd () with
  | None -> Eio.Promise.await p
  | Some fd ->
    Eio.Fiber.first
      (fun () -> Eio.Promise.await p)
      (fun () ->
         let rec pump () =
           Eio_unix.await_readable fd;
           Fetch.dispatch ();
           pump ()
         in
         pump ())

let req ?meth ?headers ?body ?timeout url = await (Fetch.req ?meth ?headers ?body ?timeout url)
let req_bs ?meth ?headers ?body ?timeout url = await (Fetch.req_bs ?meth ?headers ?body ?timeout url)

let req_stream ?meth ?headers ?body ?timeout url = await (Fetch.req_stream ?meth ?headers ?body ?timeout url)
let read ?timeout s = await (Fetch.read ?timeout s)
let read_bs ?timeout s = await (Fetch.read_bs ?timeout s)
