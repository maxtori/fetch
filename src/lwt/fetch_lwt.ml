let () = Evloop_lwt.linked ()

let promise start =
  let p, r = Lwt.wait () in
  start (Lwt.wakeup_later r);
  p

let req ?meth ?headers ?body ?timeout url = promise (Fetch.req ?meth ?headers ?body ?timeout url)
let req_bs ?meth ?headers ?body ?timeout url = promise (Fetch.req_bs ?meth ?headers ?body ?timeout url)

let req_stream ?meth ?headers ?body ?timeout url = promise (Fetch.req_stream ?meth ?headers ?body ?timeout url)
let read ?timeout s = promise (Fetch.read ?timeout s)
let read_bs ?timeout s = promise (Fetch.read_bs ?timeout s)
