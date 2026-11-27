# fetch

Async HTTP client for OCaml: Rust (reqwest, tokio) on native, the host `fetch` on JS/Wasm. Runs on [evloop](../evloop).

- `fetch`: callbacks (`req`, `req_bs`, `req_stream`/`read`/`close`, `after`/`timer`/`cancel`).
- `fetch.direct` (OCaml 5): direct style, fibers from `evloop.direct`.
- `fetch.lwt`, `fetch.eio`: Lwt / Eio.
- `fetch.ez_api_lwt`, `fetch.ez_api_eio`: ez_api engines.

```ocaml
let () = Fetch.req "https://example.com" (function
  | Ok r -> Printf.printf "%d\n" r.status
  | Error e -> prerr_endline e)

let () = Fetch_direct.spawn @@ fun () ->
  match Fetch_direct.req "https://example.com" with
  | Ok r -> Printf.printf "%d\n" r.status
  | Error e -> prerr_endline e
```

The loop runs at exit, as on JS. Native: tokio on the OCaml thread (local mode), or on a thread when another loop drives evloop.

- JS/Wasm with `fetch.direct`: `--effects=cps`.
- gzip: `make FETCH_RS_FEATURES=gzip`.
- Requires evloop, cargo (Rust ≥ 1.88), network for the crates at build time.

```sh
make && make test      # builds against ../evloop if present
```
