exception Cancelled

(* Cancellation contexts. Every fiber runs in one (the one current when it
   was started); [race] gives each branch its own. Cancelling a context
   runs its hooks: one per fiber suspended in it (which cancels what the
   fiber waits for, if possible, and resumes it with [Cancelled]), and one
   per [race] running in it (which cancels the race's branches). *)
type ctx = {
  mutable cancelled : bool;
  mutable hooks : (int * (unit -> unit)) list; (* most recent first *)
}

let root = { cancelled = false; hooks = [] }

(* The context of the fiber running now ([root] outside fibers). *)
let current = ref root
let next_hook = ref 0

let add_hook c f =
  incr next_hook;
  let id = !next_hook in
  c.hooks <- (id, f) :: c.hooks;
  id

let remove_hook c id = c.hooks <- List.filter (fun (i, _) -> i <> id) c.hooks

let cancel_ctx c =
  if not c.cancelled then begin
    c.cancelled <- true;
    let hooks = c.hooks in
    c.hooks <- [];
    List.iter (fun (_, f) -> f ()) (List.rev hooks)
  end

(* Run [f] with [c] as the current context. *)
let within c f =
  let saved = !current in
  current := c;
  match f () with
  | () -> current := saved
  | exception e -> current := saved; raise e

type _ Effect.t +=
  | Suspend : (('a -> unit) -> unit) * (unit -> unit) -> 'a Effect.t
  | Fork : (unit -> unit) -> unit Effect.t

let suspend ?(cancel = ignore) register = Effect.perform (Suspend (register, cancel))
let fork f = Effect.perform (Fork f)

(* Run [f] as a fiber. When it suspends, control goes back to whoever started
   or resumed it (ultimately: the caller of [spawn], or the event loop
   delivering a response). An uncaught exception escapes to that same place:
   the caller of [spawn], or the event loop, which then reports it; except
   [Cancelled] after the fiber's context was cancelled: the fiber just ends. *)
let rec spawn f =
  let fiber_ctx = !current in
  Effect.Deep.match_with f () {
    Effect.Deep.retc = Fun.id;
    exnc = (function
      | Cancelled when fiber_ctx.cancelled -> ()
      | e -> raise e);
    effc = (fun (type a) (e : a Effect.t) -> match e with
      | Suspend (register, cancel) ->
        Some (fun (k : (a, unit) Effect.Deep.continuation) ->
          let c = !current in
          if c.cancelled then Effect.Deep.discontinue k Cancelled
          else begin
            (* resumed at most once: by [resume], or by the cancellation *)
            let resumed = ref false in
            let hook = ref 0 in
            let resume v =
              if not !resumed then begin
                resumed := true;
                remove_hook c !hook;
                within c (fun () -> Effect.Deep.continue k v)
              end
            in
            hook := add_hook c (fun () ->
              if not !resumed then begin
                resumed := true;
                cancel ();
                within c (fun () -> Effect.Deep.discontinue k Cancelled)
              end);
            register resume
          end)
      | Fork g ->
        Some (fun (k : (a, unit) Effect.Deep.continuation) ->
          spawn g;
          Effect.Deep.continue k ())
      | _ -> None);
  }

let req ?meth ?headers ?body ?timeout url =
  suspend (fun resume -> Fetch.req ?meth ?headers ?body ?timeout url resume)

let req_bs ?meth ?headers ?body ?timeout url =
  suspend (fun resume -> Fetch.req_bs ?meth ?headers ?body ?timeout url resume)

(* Cancelled while waiting for the headers: the stream is closed as soon as
   it arrives. Cancelled during a read: the stream is closed (where it
   stands is unknown then). *)
let req_stream ?meth ?headers ?body ?timeout url =
  let cancelled = ref false in
  suspend
    ~cancel:(fun () -> cancelled := true)
    (fun resume ->
       Fetch.req_stream ?meth ?headers ?body ?timeout url (fun r ->
         if not !cancelled then resume r
         else match r with Ok { Fetch.body = s; _ } -> Fetch.close s | Error _ -> ()))

let read ?timeout s = suspend ~cancel:(fun () -> Fetch.close s) (fun resume -> Fetch.read ?timeout s resume)
let read_bs ?timeout s = suspend ~cancel:(fun () -> Fetch.close s) (fun resume -> Fetch.read_bs ?timeout s resume)

let sleep seconds =
  let timer = ref None in
  suspend
    ~cancel:(fun () -> Option.iter Fetch.cancel !timer)
    (fun resume -> timer := Some (Fetch.timer seconds resume))

module Promise = struct
  type 'a state = Resolved of 'a | Pending of ('a -> unit) list
  type 'a t = 'a state ref
  type 'a resolver = 'a -> unit

  let create () =
    let p = ref (Pending []) in
    let resolve v = match !p with
      | Resolved _ -> invalid_arg "Fetch_direct.Promise: already resolved"
      | Pending waiters ->
        p := Resolved v;
        List.iter (fun w -> w v) (List.rev waiters) in
    (p, resolve)

  (* A cancelled waiter stays in the list: resuming it then does nothing. *)
  let await p = match !p with
    | Resolved v -> v
    | Pending _ ->
      suspend (fun resume -> match !p with
        | Resolved v -> resume v
        | Pending ws -> p := Pending (resume :: ws))

  let peek p = match !p with Resolved v -> Some v | Pending _ -> None
end

let async f =
  let p, resolve = Promise.create () in
  fork (fun () -> resolve (f ()));
  p

let all fs = List.map async fs |> List.map Promise.await

let both f g =
  let pf = async f in
  let b = g () in
  (Promise.await pf, b)

let race fs =
  if fs = [] then invalid_arg "Fetch_direct.race: empty list";
  let parent = !current in
  if parent.cancelled then raise Cancelled;
  let branches = List.map (fun f -> ({ cancelled = false; hooks = [] }, f)) fs in
  let p, resolve = Promise.create () in
  let settled = ref false in
  let cancel_branches () = List.iter (fun (c, _) -> cancel_ctx c) branches in
  (* the first branch to finish settles the race and cancels the others
     (and its own context, for the fibers it may have forked) *)
  let settle r =
    if not !settled then begin
      settled := true;
      cancel_branches ();
      resolve r
    end
  in
  (* cancelling the fiber running the race cancels the branches *)
  let hook = add_hook parent cancel_branches in
  List.iter (fun (c, f) ->
    (* a branch may finish before it suspends: start no more then *)
    if not !settled then
      within c (fun () ->
        fork (fun () ->
          match f () with
          | v -> settle (Ok v)
          | exception Cancelled when c.cancelled -> ()
          | exception e -> settle (Error e))))
    branches;
  let r = Fun.protect ~finally:(fun () -> remove_hook parent hook) (fun () -> Promise.await p) in
  match r with Ok v -> v | Error e -> raise e
