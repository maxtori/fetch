(lang dune 3.25)

(generate_opam_files true)

(package
 (name fetch)
 (synopsis "Tiny async HTTP client: Rust/tokio on native, fetch on JS")
 (depends
  (ocaml (>= 4.12))
  evloop
  (conf-rust-2021 :build)
  (alcotest :with-test)
  (alcotest-lwt :with-test))
 (depopts lwt eio ez_api)
 (conflicts
  (eio (< 0.2))
  (ez_api (< 3.0.0))))
