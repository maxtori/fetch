(** Direct-style layer over {!Fetch}, with OCaml 5 effect handlers.

    The fibers are {!Evloop_direct}'s, included here: [spawn], [suspend],
    [fork], [Promise], [all], [both], [race], [Cancelled]. Other libraries
    on the same loop (idb.direct) share them, so one fiber can wait for a
    response and for anything else.

    Everything except [spawn] must be called from inside a fiber started by
    [spawn]; otherwise [Effect.Unhandled] is raised.

    On JS, executables using this library must be compiled with
    [--effects=cps], e.g. in their dune stanza:
    {v
 (js_of_ocaml
  (flags (:standard --effects=cps))
  (build_runtime_flags (:standard --effects=cps)))
    v} *)

include module type of struct include Evloop_direct end

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

(** Cancelling a fiber stops it waiting, but not everything it waits for:
    a cancelled {!sleep} cancels its timer, but a cancelled {!req} carries
    on until it completes (and keeps the event loop running until then); use
    [?timeout] to bound it. For instance, both of these give up after 5 s:
    {[
      race [ (fun () -> req url); (fun () -> sleep 5.; Error "timeout") ]
      req ~timeout:5. url
    ]}
    but only the second one aborts the request. *)
