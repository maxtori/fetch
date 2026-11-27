let has_header name headers =
  List.exists (fun (k, _) -> String.lowercase_ascii k = name) headers

let make ?msg ~meth ?(headers = []) ?content_type ?content url =
  Verbose.request ?msg ~meth ?content ~headers url;

  let headers =
    match content_type with
    | Some ct when not (has_header "content-type" headers) -> ("Content-Type", ct) :: headers
    | _ -> headers
  in
  Lwt.map
    (function
      | Ok { Fetch.status; body; _ } ->
        Verbose.response ?msg ~code:status ~content:body url;
        if status >= 200 && status < 300 then Ok body else Error (status, Some body)
      | Error e -> Error (-1, Some e))
    (Fetch_lwt.req ~meth:(`Other meth) ~headers ?body:content url)

module Interface = struct
  let get ?(meth = "GET") ?headers ?msg url = make ?msg ~meth ?headers url

  let post ?(meth = "POST") ?(content_type = "application/json") ?(content = "{}") ?headers
      ?msg url =
    make ?msg ~meth ?headers ~content_type ~content url
end

include EzRequest_lwt.Make (Interface)
