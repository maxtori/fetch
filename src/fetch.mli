(** Minimal asynchronous HTTP client with a callback API. The same code works on
    every backend:

    - native / bytecode: Rust ([tokio] current-thread runtime + [reqwest]).
      Tokio does all of the scheduling, and OCaml callbacks run on the same
      thread.
    - JavaScript (js_of_ocaml): the host [fetch] function and the JS event
      loop.

    This library does not use effects. For direct style (OCaml 5 effect
    handlers), see [fetch.direct] ({!Fetch_direct}). *)

type meth = [ `GET | `POST | `PUT | `DELETE | `PATCH | `HEAD | `OPTIONS | `Other of string ]

type bigstring = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
(** Same type as [Bigstringaf.t] and the buffers of [Cstruct.t]. *)

(** Response headers, parsed only when you look at them. *)
module Headers : sig
  type t

  val get : t -> string -> string option
  (** First value of a header. The name is case-insensitive. *)

  val get_all : t -> string -> string list
  (** All values of a header, in order. On JS, the host [fetch] has already
      merged repeated headers into one value separated by [", "]. *)

  val to_list : t -> (string * string) list
  (** Every header, in order. Names are lowercase. *)
end

type 'body response_with = {
  status : int;
  headers : Headers.t;
  body : 'body;
}

type response = string response_with
(** Body as raw bytes. *)

val req :
  ?meth:meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  ((response, string) result -> unit) ->
  unit
(** [req url k] starts a request and returns immediately. [k] is called
    exactly once, from the event loop, with the response or an error message.
    Non-2xx statuses are not errors. [k] may start further requests.

    [timeout] (seconds, none by default) bounds the whole request, from
    connecting to the end of the body: past it, the request is aborted and
    [k] gets [Error "timeout"], on every backend. Negative values count as 0.
    On JS/Wasm, a timeout over 2{^31}-1 ms (about 24 days) is ignored.
    @raise Invalid_argument if [timeout] is NaN.

    You don't have to start the event loop yourself. As in JS, it runs once
    the main program is done:
    - JS: the host event loop.
    - native: the first request registers an [at_exit] handler that runs
      {!run}. It is skipped if the program is dying from an uncaught
      exception, or if [exit] is called from a callback. If a callback raises
      during that loop, the program dies with that exception (exit code 2),
      like any uncaught exception. *)

val req_bs :
  ?meth:meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  ((bigstring response_with, string) result -> unit) ->
  unit
(** Like {!req}, but the body is a Bigarray, delivered without copying:
    on native it is the buffer Rust read the body into (freed when the GC
    collects it and every sub-array); on JS it wraps the response's
    [ArrayBuffer]. Useful for large bodies: one copy less than {!req},
    and the memory lives outside the OCaml heap. *)

val after : float -> (unit -> unit) -> unit
(** [after seconds k] returns immediately and calls [k ()] once [seconds]
    have passed, from the event loop, like JS [setTimeout]. Like a request,
    the timer counts in {!pending}: the event loop ({!run}, the at-exit loop,
    or the host loop on JS) keeps running until it has fired. Negative
    durations count as 0. To be able to cancel it, use {!timer}.

    The duration is counted from the call, even on native in local mode
    where nothing runs until the loop does: if the program is busy for
    longer than that, [k] runs as soon as the loop starts.

    @raise Invalid_argument if [seconds] is NaN. *)

(** {1 Streaming responses}

    With {!req}, the callback runs once the whole body has arrived. With
    {!req_stream}, it runs as soon as the status and headers have arrived,
    and the body is then read one chunk at a time, as it arrives: for large
    bodies, or for responses that never end (server-sent events, logs,
    long polling). A chunk is whatever the network delivered; its size
    varies. *)

type stream
(** The body of a streaming response, not yet read. *)

val req_stream :
  ?meth:meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  ((stream response_with, string) result -> unit) ->
  unit
(** Like {!req}, but [k] is called once the status and headers have
    arrived; read the body with {!read} or {!read_bs}. [timeout] (seconds)
    bounds the wait for the headers only: for a deadline on the whole
    transfer, {!close} the stream from a {!timer}.

    Read the body to its end, or {!close} the stream: until then, it keeps
    its connection (a stream collected by the GC is closed then). *)

val read :
  ?timeout:float -> stream -> ((string option, string) result -> unit) -> unit
(** [read s k] calls [k] with the next chunk of the body, [Ok (Some chunk)],
    as soon as it arrives, or [Ok None] at the end of the body (then again
    for every later read). [timeout] (seconds) bounds the wait for that
    chunk, counted from the call: when it expires, [k] gets
    [Error "timeout"]. After an error, the stream is closed, and later reads
    give [Error "closed"]. Nothing is read from the network while no read is
    pending, so time spent between reads never counts.

    @raise Invalid_argument if a read is already in progress on [s], or if
    [timeout] is NaN. *)

val read_bs :
  ?timeout:float -> stream -> ((bigstring option, string) result -> unit) -> unit
(** Like {!read}, with the chunk as a Bigarray (no copy on JS/Wasm, one copy
    less on native). *)

val close : stream -> unit
(** Stop reading: the connection is released, and a pending read gets
    [Error "closed"]. Does nothing on a stream already closed or read to
    its end. *)

type timer
(** A timer started by {!timer}. *)

val timer : float -> (unit -> unit) -> timer
(** Like {!after}, and returns the timer, to {!cancel} it.
    @raise Invalid_argument if [seconds] is NaN. *)

val cancel : timer -> unit
(** [cancel t]: [t]'s callback will not be called, and [t] no longer counts
    in {!pending}, so it no longer keeps the event loop running. Does
    nothing if [t] has already fired or been cancelled. Can be called from
    any callback, including [t]'s own. *)

val run : unit -> unit
(** Run the event loop now. Optional: use it to wait for pending requests at a
    specific point, or to catch exceptions raised by callbacks.
    - native: blocks until no request is pending. If a callback raises, the
      loop stops and [run] re-raises the exception (requests still in flight
      are resumed by the next [run]). Calling [run] from a callback fails.
    - JS/Wasm: returns immediately; the JS event loop does the work. An
      exception raised by a callback ends the program like an uncaught
      exception (exit code 2 on node). *)

(** {1 Using another event loop (Lwt, Eio, ...)}

    On native, requests only progress while fetch's own loop runs ({!run} or
    the at-exit loop), which blocks the thread. A program whose event loop
    never returns (a Lwt or Eio server, for instance) must instead switch to
    {e background mode}, before its first request: requests then run on a
    background thread, and their callbacks run when the program's loop calls
    {!dispatch}, after {!fd} becomes readable, as long as {!pending} is not 0.
    The [fetch.lwt] and [fetch.eio] libraries do all of this.

    Background mode costs some throughput on small requests (each response
    crosses threads), which is why it isn't the default.

    On JS/Wasm, the host event loop delivers responses by itself, and these
    functions do nothing. *)

val use_external_loop : unit -> unit
(** Switch to background mode: requests started from now on run on a
    background thread and must be dispatched (see above). Requests started
    before still complete, but only through {!run} or the at-exit loop. Call
    it at startup ([fetch.lwt] and [fetch.eio] do when they are linked). *)

val fd : unit -> Unix.file_descr option
(** Switches to background mode (see {!use_external_loop}) and returns a file
    descriptor that becomes readable when responses are ready to be
    dispatched. Never read from it. [None] on JS/Wasm. *)

val dispatch : unit -> unit
(** Background mode: run the callbacks of every response received so far,
    then return. Never
    blocks. If a callback raises, [dispatch] re-raises the exception; the
    remaining responses are delivered by the next call. Does nothing on
    JS/Wasm. *)

val pending : unit -> int
(** Number of requests and timers whose callback has not been called yet. *)
