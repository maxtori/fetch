(* Requests must run in the background, dispatched from the Lwt loop. Done
   when this module is initialised, i.e. before the program's first request. *)
let () = Fetch.use_external_loop ()

(* One "pump" runs in the Lwt loop while requests are pending: it waits until
   the wakeup fd is readable, then dispatches. It stops when nothing is
   pending, and the next request starts it again. *)

let lwt_fd =
  lazy (Option.map (Lwt_unix.of_unix_file_descr ~blocking:false ~set_flags:false) (Fetch.fd ()))

let pumping = ref false

let rec pump fd =
  if Fetch.pending () = 0 then Lwt.return_unit
  else Lwt.bind (Lwt_unix.wait_read fd) (fun () -> Fetch.dispatch (); pump fd)

let watch () =
  if not !pumping then
    match Lazy.force lwt_fd with
    | None -> () (* JS/Wasm: the host event loop delivers responses *)
    | Some fd ->
      pumping := true;
      (* An exception escaping a callback goes to Lwt.async_exception_hook. *)
      Lwt.async (fun () -> Lwt.finalize (fun () -> pump fd) (fun () -> pumping := false; Lwt.return_unit))

let promise start =
  let p, r = Lwt.wait () in
  start (Lwt.wakeup_later r);
  watch ();
  p

let req ?meth ?headers ?body ?timeout url = promise (Fetch.req ?meth ?headers ?body ?timeout url)
let req_bs ?meth ?headers ?body ?timeout url = promise (Fetch.req_bs ?meth ?headers ?body ?timeout url)

let req_stream ?meth ?headers ?body ?timeout url = promise (Fetch.req_stream ?meth ?headers ?body ?timeout url)
let read ?timeout s = promise (Fetch.read ?timeout s)
let read_bs ?timeout s = promise (Fetch.read_bs ?timeout s)
