(* The Eio loop drives Evloop's (evloop.eio), which runs fetch's requests
   (in background mode: linking evloop.eio makes the loop external). Without
   Evloop_eio.start, the waiting fiber dispatches until its result is in. *)

let await start =
  let p, r = Eio.Promise.create () in
  start (Eio.Promise.resolve r);
  Evloop_eio.await p

let req ?meth ?headers ?body ?timeout url = await (Fetch.req ?meth ?headers ?body ?timeout url)
let req_bs ?meth ?headers ?body ?timeout url = await (Fetch.req_bs ?meth ?headers ?body ?timeout url)

let req_stream ?meth ?headers ?body ?timeout url = await (Fetch.req_stream ?meth ?headers ?body ?timeout url)
let read ?timeout s = await (Fetch.read ?timeout s)
let read_bs ?timeout s = await (Fetch.read_bs ?timeout s)
