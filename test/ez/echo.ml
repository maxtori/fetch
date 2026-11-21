(* ez_api services on the test server, which echoes the request as JSON. *)

type t = { meth : string; url : string; body : string; ct : string }

let enc =
  Json_encoding.(
    conv
      (fun { meth; url; body; ct } -> (meth, url, body, ct))
      (fun (meth, url, body, ct) -> { meth; url; body; ct })
      (obj4 (req "method" string) (req "url" string) (req "body" string) (req "ct" string)))

let get : (t, Json_repr.ezjsonm, EzAPI.no_security) EzAPI.service0 =
  EzAPI.service ~output:enc EzAPI.Path.(root // "echo")

let post : (string list, t, Json_repr.ezjsonm, EzAPI.no_security) EzAPI.post_service0 =
  EzAPI.post_service ~input:Json_encoding.(list string) ~output:enc EzAPI.Path.(root // "echo")
