let has_header name headers =
  List.exists (fun (k, _) -> String.lowercase_ascii k = name) headers

let make ~(meth : EzAPI.Meth.t) ?(headers = []) ?msg ?content_type ?content url =
  let meth = EzAPI.Meth.to_string meth in
  Verbose.request ?msg ~meth ?content ~headers url;
  let headers =
    match content_type with
    | Some ct when not (has_header "content-type" headers) -> ("Content-Type", ct) :: headers
    | _ -> headers
  in
  match Fetch_eio.req ~meth:(`Other meth) ~headers ?body:content url with
  | Ok { Fetch.status; body; headers } ->
    Verbose.response ?msg ~code:status ~content:body url;
    (status, body, Fetch.Headers.to_list headers)
  | Error e -> (-1, e, [])

module Interface = struct
  let get ?(meth = `GET) ?headers ?msg ~net:_ ~sw:_ url = make ~meth ?headers ?msg url

  let post ?(meth = `POST) ?headers ?msg ?content_type ?content ~net:_ ~sw:_ url =
    make ~meth ?headers ?msg ?content_type ?content url
end

include EzRequestEio.Make (Interface)
