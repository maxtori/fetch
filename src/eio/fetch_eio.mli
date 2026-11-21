(** Eio integration: requests in direct style, driven by the Eio event loop.

    Use this inside [Eio_main.run]. A request suspends the calling fiber only;
    other fibers keep running. While a fiber waits, it also dispatches the
    responses of other pending requests (including those started with
    {!Fetch.req}). Native only. *)

val req :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.response, string) result

val req_bs :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.bigstring Fetch.response_with, string) result
(** Body as a Bigarray, without copying (see {!Fetch.req_bs}). *)

(** {1 Streaming responses} (see {!Fetch.req_stream}) *)

val req_stream :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.stream Fetch.response_with, string) result
(** Once the status and headers have arrived. Read the body with {!read} /
    {!read_bs}; close it with {!Fetch.close}. *)

val read : ?timeout:float -> Fetch.stream -> (string option, string) result
(** The next chunk, or [None] at the end of the body (see {!Fetch.read}). *)

val read_bs : ?timeout:float -> Fetch.stream -> (Fetch.bigstring option, string) result
