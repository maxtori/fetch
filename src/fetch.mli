(** Async HTTP client, callbacks; same code on native and JS. *)

type meth = [ `GET | `POST | `PUT | `DELETE | `PATCH | `HEAD | `OPTIONS | `Other of string ]

type bigstring = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
(** = [Bigstringaf.t]. *)

(** Parsed lazily. *)
module Headers : sig
  type t

  val get : t -> string -> string option
  (** First value; case-insensitive. *)

  val get_all : t -> string -> string list

  val to_list : t -> (string * string) list
end

type 'body response_with = {
  status : int;
  headers : Headers.t;
  body : 'body;
}

type response = string response_with

val req :
  ?meth:meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  ((response, string) result -> unit) ->
  unit
(** [k] runs once, from the event loop. *)

val req_bs :
  ?meth:meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  ((bigstring response_with, string) result -> unit) ->
  unit
(** Body as a Bigarray, without copying. *)

val after : float -> (unit -> unit) -> unit
(** Like JS [setTimeout]. *)

(** {1 Streaming responses} *)

type stream

val req_stream :
  ?meth:meth ->
  ?headers:(string * string) list ->
  ?body:string ->
  ?timeout:float ->
  string ->
  ((stream response_with, string) result -> unit) ->
  unit
(** [k] runs once the headers have arrived. *)

val read :
  ?timeout:float -> stream -> ((string option, string) result -> unit) -> unit
(** Next chunk; [None] at the end. *)

val read_bs :
  ?timeout:float -> stream -> ((bigstring option, string) result -> unit) -> unit

val close : stream -> unit
(** Releases the connection. *)

type timer

val timer : float -> (unit -> unit) -> timer

val cancel : timer -> unit

val run : unit -> unit
(** [Evloop.run]. *)

(** {1 Using another event loop (Lwt, Eio, ...)} *)

val use_external_loop : unit -> unit
(** [Evloop.use_external_loop]. *)

val fd : unit -> Unix.file_descr option
(** [Evloop.fd]. *)

val dispatch : unit -> unit
(** [Evloop.dispatch]. *)

val pending : unit -> int
(** Requests and timers not delivered yet. *)
