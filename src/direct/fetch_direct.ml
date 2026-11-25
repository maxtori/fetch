(* fetch in direct style: the fibers are evloop.direct's (shared with other
   libraries on Evloop's loop, such as idb.direct), plus fetch's requests
   and timers as suspending functions. *)

include Evloop_direct

let req ?meth ?headers ?body ?timeout url =
  suspend (fun resume -> Fetch.req ?meth ?headers ?body ?timeout url resume)

let req_bs ?meth ?headers ?body ?timeout url =
  suspend (fun resume -> Fetch.req_bs ?meth ?headers ?body ?timeout url resume)

(* Cancelled while waiting for the headers: the stream is closed as soon as
   it arrives. Cancelled during a read: the stream is closed (where it
   stands is unknown then). *)
let req_stream ?meth ?headers ?body ?timeout url =
  let cancelled = ref false in
  suspend
    ~cancel:(fun () -> cancelled := true)
    (fun resume ->
       Fetch.req_stream ?meth ?headers ?body ?timeout url (fun r ->
         if not !cancelled then resume r
         else match r with Ok { Fetch.body = s; _ } -> Fetch.close s | Error _ -> ()))

let read ?timeout s = suspend ~cancel:(fun () -> Fetch.close s) (fun resume -> Fetch.read ?timeout s resume)
let read_bs ?timeout s = suspend ~cancel:(fun () -> Fetch.close s) (fun resume -> Fetch.read_bs ?timeout s resume)

let sleep seconds =
  let timer = ref None in
  suspend
    ~cancel:(fun () -> Option.iter Fetch.cancel !timer)
    (fun resume -> timer := Some (Fetch.timer seconds resume))
