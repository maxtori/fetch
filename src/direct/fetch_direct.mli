(** Direct-style layer over {!Fetch}, implemented with OCaml 5 effect handlers.

    Everything except {!spawn} must be called from inside a fiber started by
    {!spawn}; otherwise [Effect.Unhandled] is raised.

    On JS, executables using this library must be compiled with
    [--effects=cps], e.g. in their dune stanza:
    {v
 (js_of_ocaml
  (flags (:standard --effects=cps))
  (build_runtime_flags (:standard --effects=cps)))
    v} *)

exception Cancelled
(** Raised in a fiber cancelled by {!race}, at the point where it is
    suspended (or as soon as it tries to suspend again). Let it propagate:
    it unwinds the fiber, running its [Fun.protect] finalizers, and the
    fiber then ends silently. *)

val spawn : (unit -> unit) -> unit
(** [spawn main] runs [main] as a fiber (under the effect handler) and returns
    as soon as it first suspends, on every backend. The event loop then runs
    once the main program is done (see {!Fetch.req}). To wait at a
    given point instead, call {!Fetch.run}.

    An uncaught exception in a fiber escapes to whoever is running it: the
    caller of [spawn] before the first suspension, then the event loop. So on
    native it is raised by {!Fetch.run}, or kills the program when the loop
    runs at exit. On JS it surfaces as an unhandled promise rejection.
    Can also be called from inside a fiber (like {!fork}). *)

val req :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.response, string) result
(** Suspends the current fiber until the response arrives. *)

val req_bs :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.bigstring Fetch.response_with, string) result
(** Like {!req}, with the body as a Bigarray (no copy, see
    {!Fetch.req_bs}). *)

val req_stream :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.stream Fetch.response_with, string) result
(** Suspends until the status and headers arrive (see {!Fetch.req_stream}).
    Read the body with {!read} / {!read_bs}, and close it with
    {!Fetch.close}. If the fiber is cancelled meanwhile, the stream is closed
    when it arrives. *)

val read : ?timeout:float -> Fetch.stream -> (string option, string) result
(** Suspends until the next chunk ([Some chunk]) or the end of the body
    ([None]); see {!Fetch.read}. If the fiber is cancelled meanwhile, the
    stream is closed. *)

val read_bs : ?timeout:float -> Fetch.stream -> (Fetch.bigstring option, string) result
(** Like {!read}, with the chunk as a Bigarray. *)

val sleep : float -> unit
(** [sleep seconds] suspends the current fiber for [seconds] (see
    {!Fetch.after}); other fibers and requests keep running. *)

val fork : (unit -> unit) -> unit
(** Start a new fiber. It runs immediately until its first suspension. *)

val suspend : ?cancel:(unit -> unit) -> (('a -> unit) -> unit) -> 'a
(** [suspend register] suspends the current fiber and calls [register resume].
    Calling [resume v] later resumes the fiber with [v]; calls after the
    first one do nothing. Use it to turn any callback-based API into direct
    style.

    If the fiber is cancelled meanwhile (see {!race}), [cancel ()] is called
    (to cancel what the fiber was waiting for, if possible: [sleep] cancels
    its timer) and the fiber is resumed with {!Cancelled}; a later [resume]
    does nothing. *)

module Promise : sig
  type 'a t
  type 'a resolver = 'a -> unit

  val create : unit -> 'a t * 'a resolver
  val await : 'a t -> 'a
  val peek : 'a t -> 'a option
end

val async : (unit -> 'a) -> 'a Promise.t
val all : (unit -> 'a) list -> 'a list
(** Run all functions concurrently and return their results in order. *)

val both : (unit -> 'a) -> (unit -> 'b) -> 'a * 'b

val race : (unit -> 'a) list -> 'a
(** [race fs] runs the functions concurrently, each in its own fiber, and
    returns the result of the first one to finish, or raises its exception.
    The others are then cancelled (see {!Cancelled}), along with the fibers
    they have started. Branches are started in order, and once one has
    finished no other one is started.

    Cancelling a fiber stops it waiting, but not everything it waits for:
    a cancelled {!sleep} cancels its timer, but a cancelled {!req} carries
    on until it completes (and keeps the event loop running until then); use
    [?timeout] to bound it. For instance, both of these give up after 5 s:
    {[
      race [ (fun () -> req url); (fun () -> sleep 5.; Error "timeout") ]
      req ~timeout:5. url
    ]}
    but only the second one aborts the request.

    If the fiber running [race] is itself cancelled, the branches are too.
    @raise Invalid_argument on an empty list. *)
