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
external prim_run : unit -> unit = "caml_fetch_run"
external prim_dispatch : unit -> unit = "caml_fetch_dispatch"
external prim_fd : unit -> Unix.file_descr option = "caml_fetch_fd"
external prim_use_background : unit -> unit = "caml_fetch_use_background"
external named_value : string -> Obj.t option = "caml_fetch_named_value"

(* Event loop *)

let is_js = match Sys.backend_type with Sys.Other _ -> true | _ -> false
let in_run = ref false

let run () =
  if !in_run then failwith "Fetch.run: already running (nested call)";
  in_run := true;
  Fun.protect ~finally:(fun () -> in_run := false) prim_run

(* Implicit loop at exit (native/bytecode only)

   Like in JS, the loop runs once the main program is done. It is skipped
   when the program is dying from an uncaught exception, and when [exit] is
   called from a callback (the loop is already running). *)

let crashing = ref false

(* At-exit handlers also run when the program dies from an uncaught exception,
   with nothing telling them apart from a normal exit. The runtime reports
   such exceptions through the named value below (registered by Printexc,
   which is initialised before this module), so wrap it to record the crash. *)
let watch_uncaught_exceptions () =
  (* Referencing Printexc forces it to be linked and initialised first. *)
  ignore (Printexc.backtrace_status ());
  let name = "Printexc.handle_uncaught_exception" in
  Option.iter (fun h ->
    let handler : exn -> bool -> unit = Obj.obj h in
    Callback.register name (fun exn debugger ->
      crashing := true;
      handler exn debugger)
  ) @@ named_value name

let loop_at_exit () =
  (* If a callback raises here, the exception escapes from the exit handlers
     and the runtime reports it as uncaught (exit code 2), as for any other
     exit handler. [crashing] is then set, so the loop is not run again. *)
  if not (!crashing || !in_run) then run ()

let at_exit_registered = ref false

let ensure_loop_at_exit () =
  if not (is_js || !at_exit_registered) then (
    at_exit_registered := true;
    watch_uncaught_exceptions ();
    at_exit loop_at_exit)

(* Requests *)

let string_of_meth = function
  | `GET -> "GET" | `POST -> "POST" | `PUT -> "PUT" | `DELETE -> "DELETE"
  | `PATCH -> "PATCH" | `HEAD -> "HEAD" | `OPTIONS -> "OPTIONS"
  | `Other m -> m

(* Requests started and not yet delivered to their callback. *)
let pending_count = ref 0
let pending () = !pending_count

let wrap k r =
  decr pending_count;
  match r with
  | Ok (status, headers, body) -> k (Ok { status; headers; body })
  | Error _ as e -> k e

let timeout_arg = function
  | None -> -1.
  | Some t when Float.is_nan t -> invalid_arg "Fetch: timeout is NaN"
  | Some t -> Float.max 0. t

let req ?(meth = `GET) ?(headers = []) ?body ?timeout url k =
  let timeout = timeout_arg timeout in
  ensure_loop_at_exit ();
  prim_request (string_of_meth meth) url (Array.of_list headers) body timeout (wrap k);
  (* after the call: if it raises, nothing is pending. Callbacks are never
     called synchronously, so the count cannot go negative. *)
  incr pending_count

let req_bs ?(meth = `GET) ?(headers = []) ?body ?timeout url k =
  let timeout = timeout_arg timeout in
  ensure_loop_at_exit ();
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
  ensure_loop_at_exit ();
  let t = { live = true; id = None } in
  t.id <- Some (prim_after seconds (fun () ->
    if t.live then begin
      t.live <- false;
      decr pending_count;
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
  ensure_loop_at_exit ();
  let id = ref None in
  id := Some (prim_stream_open (string_of_meth meth) url (Array.of_list headers) body timeout (fun r ->
    decr pending_count;
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
      decr pending_count;
      (* if [close] was called meanwhile, the stream stays closed *)
      if s.state = Reading then
        s.state <- (match r with Ok (Some _) -> Idle | Ok None -> Ended | Error _ -> Closed);
      k r);
    (* after the call, as for requests: if it raises, nothing changes *)
    s.state <- Reading;
    incr pending_count

let read ?timeout s k = read_with prim_stream_read ?timeout s k
let read_bs ?timeout s k = read_with prim_stream_read_bigstring ?timeout s k

(* Integration with other event loops *)

let use_external_loop () = if not is_js then prim_use_background ()
let fd () = if is_js then None else prim_fd ()
let dispatch () = if not is_js then prim_dispatch ()
