(** Direct style; fibers from {!Evloop_direct}. *)

include module type of struct include Evloop_direct end

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

val req_stream :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.stream Fetch.response_with, string) result

val read : ?timeout:float -> Fetch.stream -> (string option, string) result

val read_bs : ?timeout:float -> Fetch.stream -> (Fetch.bigstring option, string) result

val sleep : float -> unit

