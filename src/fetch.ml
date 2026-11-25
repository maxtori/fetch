type meth = [ `GET | `POST | `PUT | `DELETE | `PATCH | `HEAD | `OPTIONS | `Other of string ]

type bigstring = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

(* Headers as received from the backend: "name:value\n" for each header. *)
module Headers = struct
  type t = string

  let header t i =
    let colon = String.index_from t i ':' in
    (colon, String.index_from t colon '\n')

  let fold f acc t =
    let rec go acc i =
      if i >= String.length t then acc else
      let colon, nl = header t i in
      go (f acc i colon nl) (nl + 1) in
    go acc 0

  let name_is t i colon name =
    let len = String.length name in
    let rec eq j =
      j = len || (Char.lowercase_ascii t.[i + j] = Char.lowercase_ascii name.[j] && eq (j + 1)) in
    colon - i = len && eq 0

  let value t colon nl = String.sub t (colon + 1) (nl - colon - 1)

  let get_all t name =
    List.rev (fold (fun acc i colon nl -> if name_is t i colon name then value t colon nl :: acc else acc) [] t)

  let get t name =
    let rec go i =
      if i >= String.length t then None else
      let colon, nl = header t i in
      if name_is t i colon name then Some (value t colon nl) else go (nl + 1) in
    go 0

  let to_list t =
    List.rev (fold (fun acc i colon nl -> (String.sub t i (colon - i), value t colon nl) :: acc) [] t)
end

type 'body response_with = {
  status : int;
  headers : Headers.t;
  body : 'body;
}

type response = string response_with

(* Primitives: implemented in fetch_stubs.c, fetch_runtime.js and fetch_runtime.wat *)

type 'body raw_response = int * string * 'body

(* The timeout is in seconds, negative for none. Six arguments: separate
   bytecode and native stubs (JS and Wasm implement the bytecode name). *)
external prim_request :
  string -> string -> (string * string) array -> string option -> float ->
  ((string raw_response, string) result -> unit) -> unit
  = "caml_fetch_request" "caml_fetch_request_nat"

external prim_request_bigstring :
  string -> string -> (string * string) array -> string option -> float ->
  ((bigstring raw_response, string) result -> unit) -> unit
  = "caml_fetch_request_bigstring" "caml_fetch_request_bigstring_nat"

(* native: an int; JS/Wasm: the object holding the setTimeout handle *)
type timer_id
external prim_after : float -> (unit -> unit) -> timer_id = "caml_fetch_after"
external prim_cancel_timer : timer_id -> unit = "caml_fetch_cancel_timer"

(* native: an int; JS/Wasm: the object holding the reader *)
type stream_id

external prim_stream_open :
  string -> string -> (string * string) array -> string option -> float ->
  ((unit raw_response, string) result -> unit) -> stream_id
  = "caml_fetch_stream_open" "caml_fetch_stream_open_nat"

external prim_stream_read :
  stream_id -> float -> ((string option, string) result -> unit) -> unit = "caml_fetch_stream_read"

external prim_stream_read_bigstring :
  stream_id -> float -> ((bigstring option, string) result -> unit) -> unit
  = "caml_fetch_stream_read_bigstring"

external prim_stream_close : stream_id -> unit = "caml_fetch_stream_close"
external prim_dispatch : unit -> unit = "caml_fetch_dispatch"
external prim_use_background : unit -> unit = "caml_fetch_use_background"
external prim_run_local_until : Unix.file_descr -> bool = "caml_fetch_run_local_until"
external prim_set_wake_fd : Unix.file_descr -> unit = "caml_fetch_set_wake_fd"

(* Event loop: fetch is a source of Evloop's loop (native).

   - Background mode (an external loop drives Evloop's): completions are
     delivered on each turn ([run_ready]).
   - Local mode: requests only progress inside tokio, on this thread; the
     loop lets tokio run when it has nothing else to do ([block]), until the
     requests are done or another source has work (the wakeup fd). *)

let is_js = match Sys.backend_type with Sys.Other _ -> true | _ -> false

(* Requests and timers started and not yet delivered to their callback. *)
let pending_count = ref 0
let pending () = !pending_count

(* Callbacks run: progress for the loop. *)
let deliveries = ref 0
let delivered () = decr pending_count; incr deliveries

let source = {
  Evloop.run_ready = (fun () ->
    let before = !deliveries in
    prim_dispatch ();
    !deliveries <> before);
  ready = (fun () -> false);
  waiting = (fun () -> !pending_count > 0);
  block = (fun () -> prim_run_local_until (Evloop.wake_fd ()));
}

let registered = ref false
let background = ref false

(* Before each request or timer: join the loop, and use background mode if
   another loop drives it. *)
let prepare () =
  if not is_js then begin
    if not !registered then begin
      registered := true;
      Evloop.ensure_loop_at_exit ();
      prim_set_wake_fd (Evloop.wake_write_fd ());
      Evloop.register source
    end;
    if Evloop.is_external () && not !background then begin
      background := true;
      prim_use_background ()
    end
  end

let run = Evloop.run

(* Requests *)

let string_of_meth = function
  | `GET -> "GET" | `POST -> "POST" | `PUT -> "PUT" | `DELETE -> "DELETE"
  | `PATCH -> "PATCH" | `HEAD -> "HEAD" | `OPTIONS -> "OPTIONS"
  | `Other m -> m

let wrap k r =
  delivered ();
  match r with
  | Ok (status, headers, body) -> k (Ok { status; headers; body })
  | Error _ as e -> k e

let timeout_arg = function
  | None -> -1.
  | Some t when Float.is_nan t -> invalid_arg "Fetch: timeout is NaN"
  | Some t -> Float.max 0. t

let req ?(meth = `GET) ?(headers = []) ?body ?timeout url k =
  let timeout = timeout_arg timeout in
  prepare ();
  prim_request (string_of_meth meth) url (Array.of_list headers) body timeout (wrap k);
  (* after the call: if it raises, nothing is pending. Callbacks are never
     called synchronously, so the count cannot go negative. *)
  incr pending_count

let req_bs ?(meth = `GET) ?(headers = []) ?body ?timeout url k =
  let timeout = timeout_arg timeout in
  prepare ();
  prim_request_bigstring (string_of_meth meth) url (Array.of_list headers) body timeout (wrap k);
  incr pending_count

(* Timers *)

(* [live] until the timer fires or is cancelled, whichever comes first: the
   other one then does nothing. A cancelled timer may still be delivered
   (native: right after the cancellation, or if it had already fired): that
   delivery is ignored. *)
type timer = { mutable live : bool; mutable id : timer_id option }

let timer seconds k =
  if Float.is_nan seconds then invalid_arg "Fetch.timer: NaN";
  prepare ();
  let t = { live = true; id = None } in
  t.id <- Some (prim_after seconds (fun () ->
    if t.live then begin
      t.live <- false;
      delivered ();
      k ()
    end));
  incr pending_count;
  t

let cancel t =
  if t.live then begin
    t.live <- false;
    decr pending_count;
    Option.iter prim_cancel_timer t.id
  end

let after seconds k =
  if Float.is_nan seconds then invalid_arg "Fetch.after: NaN";
  ignore (timer seconds k)

(* Streams *)

type stream_state =
  | Idle
  | Reading (* one read at a time *)
  | Ended (* the body has ended: reads give [Ok None] *)
  | Closed (* by [close], an error or a timeout: reads give [Error "closed"] *)

type stream = { id : stream_id; mutable state : stream_state }

let close s =
  match s.state with
  | Ended | Closed -> ()
  | Idle | Reading ->
    s.state <- Closed;
    prim_stream_close s.id

let req_stream ?(meth = `GET) ?(headers = []) ?body ?timeout url k =
  let timeout = timeout_arg timeout in
  prepare ();
  let id = ref None in
  id := Some (prim_stream_open (string_of_meth meth) url (Array.of_list headers) body timeout (fun r ->
    delivered ();
    match r with
    | Ok (status, headers, ()) ->
      let s = { id = Option.get !id; state = Idle } in
      (* a stream dropped without being read to the end or closed would
         keep its connection: close it when the GC collects it *)
      Gc.finalise close s;
      k (Ok { status; headers; body = s })
    | Error _ as e -> k e));
  incr pending_count

let read_with prim ?timeout s k =
  let timeout = timeout_arg timeout in
  match s.state with
  | Reading -> invalid_arg "Fetch.read: a read is already in progress on this stream"
  (* callbacks are never called synchronously *)
  | Ended -> after 0. (fun () -> k (Ok None))
  | Closed -> after 0. (fun () -> k (Error "closed"))
  | Idle ->
    prim s.id timeout (fun r ->
      delivered ();
      (* if [close] was called meanwhile, the stream stays closed *)
      if s.state = Reading then
        s.state <- (match r with Ok (Some _) -> Idle | Ok None -> Ended | Error _ -> Closed);
      k r);
    (* after the call, as for requests: if it raises, nothing changes *)
    s.state <- Reading;
    incr pending_count

let read ?timeout s k = read_with prim_stream_read ?timeout s k
let read_bs ?timeout s k = read_with prim_stream_read_bigstring ?timeout s k

(* Integration with other event loops: Evloop's *)

let use_external_loop () = Evloop.use_external_loop ()
let fd = Evloop.fd
let dispatch = Evloop.dispatch
