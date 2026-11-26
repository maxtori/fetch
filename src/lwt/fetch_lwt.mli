(** Lwt integration: requests as Lwt promises, driven by the Lwt event loop.

    Use this in programs whose main loop is [Lwt_main.run] (a server, for
    instance). The callbacks of {e all} pending requests, including those
    started with {!Fetch.req} directly, are dispatched from the Lwt loop while
    requests are pending. Native only ([lwt.unix]). *)

val req :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.response, string) result Lwt.t

val req_bs :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.bigstring Fetch.response_with, string) result Lwt.t
(** Body as a Bigarray, without copying (see {!Fetch.req_bs}). *)

(** {1 Streaming responses} (see {!Fetch.req_stream}) *)

val req_stream :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.stream Fetch.response_with, string) result Lwt.t
(** Once the status and headers have arrived. Read the body with {!read} /
    {!read_bs}; close it with {!Fetch.close}. *)

val read : ?timeout:float -> Fetch.stream -> (string option, string) result Lwt.t
(** The next chunk, or [None] at the end of the body (see {!Fetch.read}). *)

val read_bs : ?timeout:float -> Fetch.stream -> (Fetch.bigstring option, string) result Lwt.t
