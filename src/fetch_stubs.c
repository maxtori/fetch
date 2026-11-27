#define CAML_NAME_SPACE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

typedef struct {
  const char *name;
  size_t name_len;
  const char *value;
  size_t value_len;
} fetch_header;

typedef int (*fetch_done_cb)(void *ctx, int status, const char *headers,
                             size_t headers_len, char *body, size_t body_len,
                             const char *err, size_t err_len);

extern int fetch_rs_request(const char *method, size_t method_len,
                            const char *url, size_t url_len,
                            const fetch_header *headers, size_t n_headers,
                            const char *body, size_t body_len, int has_body,
                            double timeout, void *ctx, fetch_done_cb cb);
extern int64_t fetch_rs_after(double seconds, void *ctx, fetch_done_cb cb);
extern int64_t fetch_rs_stream_open(const char *method, size_t method_len,
                                    const char *url, size_t url_len,
                                    const fetch_header *headers,
                                    size_t n_headers, const char *body,
                                    size_t body_len, int has_body,
                                    double timeout, void *ctx,
                                    fetch_done_cb cb);
extern int fetch_rs_stream_read(uint64_t id, double timeout, void *ctx,
                                fetch_done_cb cb);
extern void fetch_rs_stream_close(uint64_t id);
extern void fetch_rs_cancel_timer(uint64_t id);

extern int fetch_rs_run_local_until(int fd);

extern void fetch_rs_use_background(void);
extern void fetch_rs_set_wake_fd(int fd);
extern int fetch_rs_dispatch(void);

enum kind {
  BODY_STRING,
  BODY_BIGSTRING,
  TIMER,
  STREAM_HEAD,
  CHUNK_STRING,
  CHUNK_BIGSTRING
};

typedef struct {
  value cb;
  enum kind kind;
} request_ctx;

static value pending_exn = Val_unit;
static int pending_exn_registered = 0;

static value body_value(int bigstring, char *body, size_t body_len) {
  if (bigstring) {

    if (body == NULL) body = malloc(1);
    if (body == NULL) caml_raise_out_of_memory();
    intnat dim = (intnat)body_len;
    return caml_ba_alloc(CAML_BA_CHAR | CAML_BA_C_LAYOUT | CAML_BA_MANAGED, 1,
                         body, &dim);
  } else {
    value s = caml_alloc_initialized_string(body_len, body);
    free(body);
    return s;
  }
}

static int on_done(void *ctx, int status, const char *headers,
                   size_t headers_len, char *body, size_t body_len,
                   const char *err, size_t err_len) {
  CAMLparam0();
  CAMLlocal5(cb, res, payload, hdrs, tmp);
  request_ctx *rc = (request_ctx *)ctx;
  enum kind kind = rc->kind;
  cb = rc->cb;
  caml_remove_generational_global_root(&rc->cb);
  free(rc);

  if (kind == TIMER) {
    free(body);
    res = Val_unit;
  } else if (err != NULL) {
    payload = caml_alloc_initialized_string(err_len, err);
    res = caml_alloc_small(1, 1);
    Field(res, 0) = payload;
  } else if ((kind == CHUNK_STRING || kind == CHUNK_BIGSTRING) && status == 0) {
    free(body);
    res = caml_alloc_small(1, 0);
    Field(res, 0) = Val_none;
  } else if (kind == CHUNK_STRING || kind == CHUNK_BIGSTRING) {
    tmp = body_value(kind == CHUNK_BIGSTRING, body, body_len);
    payload = caml_alloc_some(tmp);
    res = caml_alloc_small(1, 0);
    Field(res, 0) = payload;
  } else {
    hdrs = caml_alloc_initialized_string(headers_len, headers);
    if (kind == STREAM_HEAD) {
      free(body);
      tmp = Val_unit;
    } else {
      tmp = body_value(kind == BODY_BIGSTRING, body, body_len);
    }
    payload = caml_alloc_tuple(3);
    Store_field(payload, 0, Val_int(status));
    Store_field(payload, 1, hdrs);
    Store_field(payload, 2, tmp);
    res = caml_alloc_small(1, 0);
    Field(res, 0) = payload;
  }

  tmp = caml_callback_exn(cb, res);
  if (Is_exception_result(tmp)) {
    if (!pending_exn_registered) {
      caml_register_generational_global_root(&pending_exn);
      pending_exn_registered = 1;
    }
    caml_modify_generational_global_root(&pending_exn,
                                         Extract_exception(tmp));
    CAMLreturnT(int, 1);
  }
  CAMLreturnT(int, 0);
}

static request_ctx *new_ctx(value *cb, enum kind kind) {
  request_ctx *rc = malloc(sizeof(request_ctx));
  if (rc == NULL) return NULL;
  rc->cb = *cb;
  rc->kind = kind;
  caml_register_generational_global_root(&rc->cb);
  return rc;
}

static void free_ctx(request_ctx *rc) {
  caml_remove_generational_global_root(&rc->cb);
  free(rc);
}

static value request(value meth, value url, value headers, value body,
                     value timeout, value cb, enum kind kind) {
  CAMLparam5(meth, url, headers, body, timeout);
  CAMLxparam1(cb);
  size_t n = Wosize_val(headers);
  fetch_header *hs = NULL;
  if (n > 0) {
    hs = malloc(n * sizeof(fetch_header));
    if (hs == NULL) caml_raise_out_of_memory();
  }

  for (size_t i = 0; i < n; i++) {
    value h = Field(headers, i);
    hs[i].name = String_val(Field(h, 0));
    hs[i].name_len = caml_string_length(Field(h, 0));
    hs[i].value = String_val(Field(h, 1));
    hs[i].value_len = caml_string_length(Field(h, 1));
  }

  request_ctx *rc = new_ctx(&cb, kind);
  if (rc == NULL) { free(hs); caml_raise_out_of_memory(); }

  int has_body = Is_some(body);
  value b = has_body ? Some_val(body) : Val_unit;
  const char *bp = has_body ? String_val(b) : NULL;
  size_t blen = has_body ? caml_string_length(b) : 0;
  int64_t r;
  if (kind == STREAM_HEAD)
    r = fetch_rs_stream_open(String_val(meth), caml_string_length(meth),
                             String_val(url), caml_string_length(url), hs, n,
                             bp, blen, has_body, Double_val(timeout), rc,
                             on_done);
  else
    r = fetch_rs_request(String_val(meth), caml_string_length(meth),
                         String_val(url), caml_string_length(url), hs, n, bp,
                         blen, has_body, Double_val(timeout), rc, on_done);
  free(hs);
  if (kind == STREAM_HEAD ? r < 0 : r != 0) {
    free_ctx(rc);
    caml_failwith("Fetch: could not queue request");
  }
  CAMLreturn(kind == STREAM_HEAD ? Val_long(r) : Val_unit);
}

value caml_fetch_request_nat(value meth, value url, value headers, value body,
                             value timeout, value cb) {
  return request(meth, url, headers, body, timeout, cb, BODY_STRING);
}

value caml_fetch_request(value *argv, int argn) {
  (void)argn;
  return caml_fetch_request_nat(argv[0], argv[1], argv[2], argv[3], argv[4],
                                argv[5]);
}

value caml_fetch_request_bigstring_nat(value meth, value url, value headers,
                                       value body, value timeout, value cb) {
  return request(meth, url, headers, body, timeout, cb, BODY_BIGSTRING);
}

value caml_fetch_request_bigstring(value *argv, int argn) {
  (void)argn;
  return caml_fetch_request_bigstring_nat(argv[0], argv[1], argv[2], argv[3],
                                          argv[4], argv[5]);
}

value caml_fetch_stream_open_nat(value meth, value url, value headers,
                                 value body, value timeout, value cb) {
  return request(meth, url, headers, body, timeout, cb, STREAM_HEAD);
}

value caml_fetch_stream_open(value *argv, int argn) {
  (void)argn;
  return caml_fetch_stream_open_nat(argv[0], argv[1], argv[2], argv[3],
                                    argv[4], argv[5]);
}

static value stream_read(value id, value timeout, value cb, enum kind kind) {
  CAMLparam3(id, timeout, cb);
  request_ctx *rc = new_ctx(&cb, kind);
  if (rc == NULL) caml_raise_out_of_memory();
  if (fetch_rs_stream_read((uint64_t)Long_val(id), Double_val(timeout), rc,
                           on_done) != 0) {
    free_ctx(rc);
    caml_failwith("Fetch: could not queue read");
  }
  CAMLreturn(Val_unit);
}

value caml_fetch_stream_read(value id, value timeout, value cb) {
  return stream_read(id, timeout, cb, CHUNK_STRING);
}

value caml_fetch_stream_read_bigstring(value id, value timeout, value cb) {
  return stream_read(id, timeout, cb, CHUNK_BIGSTRING);
}

value caml_fetch_stream_close(value id) {
  fetch_rs_stream_close((uint64_t)Long_val(id));
  return Val_unit;
}

value caml_fetch_after(value seconds, value cb) {
  CAMLparam2(seconds, cb);
  request_ctx *rc = new_ctx(&cb, TIMER);
  if (rc == NULL) caml_raise_out_of_memory();
  int64_t id = fetch_rs_after(Double_val(seconds), rc, on_done);
  if (id < 0) {
    free_ctx(rc);
    caml_failwith("Fetch: could not queue timer");
  }
  CAMLreturn(Val_long(id));
}

value caml_fetch_cancel_timer(value id) {
  fetch_rs_cancel_timer((uint64_t)Long_val(id));
  return Val_unit;
}

static void raise_pending_exn(void) {
  if (pending_exn != Val_unit) {
    value e = pending_exn;
    caml_modify_generational_global_root(&pending_exn, Val_unit);
    caml_raise(e);
  }
}

value caml_fetch_dispatch(value unit) {
  CAMLparam1(unit);
  fetch_rs_dispatch();
  raise_pending_exn();
  CAMLreturn(Val_unit);
}

value caml_fetch_run_local_until(value fd) {
  CAMLparam1(fd);
  int r = fetch_rs_run_local_until(Int_val(fd));
  if (r == 1) caml_failwith("Fetch: the event loop is already running (nested call)");
  if (r == 2) caml_failwith("Fetch: event loop panicked");
  raise_pending_exn();
  CAMLreturn(Val_bool(r != 3));
}

value caml_fetch_set_wake_fd(value fd) {
  fetch_rs_set_wake_fd(Int_val(fd));
  return Val_unit;
}

value caml_fetch_use_background(value unit) {
  fetch_rs_use_background();
  return Val_unit;
}
