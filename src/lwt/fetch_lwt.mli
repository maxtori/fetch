(** Lwt promises. *)

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

(** {1 Streaming responses} *)

val req_stream :
  ?meth:Fetch.meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  (Fetch.stream Fetch.response_with, string) result Lwt.t

val read : ?timeout:float -> Fetch.stream -> (string option, string) result Lwt.t

val read_bs : ?timeout:float -> Fetch.stream -> (Fetch.bigstring option, string) result Lwt.t
