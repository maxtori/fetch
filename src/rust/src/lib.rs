//! Rust side of the native backend. Requests are performed by tokio, in one of
//! two modes (chosen per program, see `fetch_rs_use_background`):
//!
//! - **Local mode** (default): a current-thread tokio runtime on the OCaml
//!   thread. Requests only progress inside `fetch_rs_run_local` (`Fetch.run`
//!   and the at-exit loop), which blocks the thread in tokio; when a request
//!   is done, its task calls the C/OCaml callback directly. No threads, no
//!   hand-off: the fastest mode for programs that let fetch drive the loop.
//!
//! - **Background mode**, for programs running their own event loop (Lwt, Eio,
//!   a server...): tokio runs on a background thread for the whole life of the
//!   program, never touching OCaml values. A finished request is pushed onto a
//!   completion queue, and an eventfd (a pipe on non-Linux systems) becomes
//!   readable. The OCaml thread delivers completions with `fetch_rs_dispatch`
//!   when its event loop sees the fd readable (`fetch_rs_fd`).
//!
//! Timers (`fetch_rs_after`) are tasks too, delivered the same way.
//!
//! In both modes, OCaml callbacks run on the OCaml thread only.
//! This crate knows nothing about OCaml values: it only exposes a plain C ABI.

use std::cell::Cell;
use std::collections::{HashMap, VecDeque};
use std::ffi::{c_int, c_void};
use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use tokio::runtime::{Builder, Handle, Runtime};
use tokio::sync::Notify;
use tokio::task::LocalSet;

#[repr(C)]
pub struct FetchHeader {
    pub name: *const u8,
    pub name_len: usize,
    pub value: *const u8,
    pub value_len: usize,
}

/// Completion callback. On success `err` is NULL. On failure `status` is 0 and
/// `err`/`err_len` describe the error.
///
/// - `headers` is every response header as `name:value\n`, in order (names
///   are lowercase); only valid during the call.
/// - `body` was allocated with `malloc` and is handed over to the callee,
///   which must eventually `free` it (it may be NULL when `body_len` is 0).
///
/// A non-zero return value stops the loop or the dispatch (used to propagate
/// an OCaml exception); remaining requests are delivered later.
pub type DoneCb = extern "C" fn(
    ctx: *mut c_void,
    status: c_int,
    headers: *const u8,
    headers_len: usize,
    body: *mut u8,
    body_len: usize,
    err: *const u8,
    err_len: usize,
) -> c_int;

/// Growable byte buffer allocated with the C allocator, so that its memory can
/// be handed to OCaml (as a managed Bigarray) without copying.
struct MallocBuf {
    ptr: *mut u8,
    len: usize,
    cap: usize,
}

// Owned by exactly one place at a time (in background mode: filled on the
// tokio thread, then handed to the OCaml thread through the queue).
unsafe impl Send for MallocBuf {}

impl MallocBuf {
    fn new() -> Self {
        MallocBuf { ptr: std::ptr::null_mut(), len: 0, cap: 0 }
    }

    fn reserve(&mut self, additional: usize) -> Result<(), String> {
        let needed = self.len.checked_add(additional).ok_or("body too large")?;
        if needed <= self.cap {
            return Ok(());
        }
        let cap = needed.max(self.cap.saturating_mul(2)).max(64);
        let p = unsafe { libc::realloc(self.ptr as *mut c_void, cap) } as *mut u8;
        if p.is_null() {
            return Err("out of memory".into());
        }
        self.ptr = p;
        self.cap = cap;
        Ok(())
    }

    fn extend(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.reserve(bytes.len())?;
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), self.ptr.add(self.len), bytes.len()) };
        self.len += bytes.len();
        Ok(())
    }

    /// Give up ownership: the caller must `free` the pointer.
    fn into_raw(self) -> (*mut u8, usize) {
        let r = (self.ptr, self.len);
        std::mem::forget(self);
        r
    }
}

impl Drop for MallocBuf {
    fn drop(&mut self) {
        unsafe { libc::free(self.ptr as *mut c_void) }
    }
}

struct Request {
    method: Vec<u8>,
    url: String,
    headers: Vec<(Vec<u8>, Vec<u8>)>,
    body: Option<Vec<u8>>,
    timeout: Option<Duration>,
}

struct Response {
    status: u16,
    headers: Vec<u8>, // "name:value\n" for each header
    body: MallocBuf,
}

fn error_chain(e: &dyn std::error::Error) -> String {
    let mut s = e.to_string();
    let mut cur = e.source();
    while let Some(src) = cur {
        s.push_str(": ");
        s.push_str(&src.to_string());
        cur = src.source();
    }
    s
}

thread_local! {
    // One client per thread that performs requests (the OCaml thread in local
    // mode, the tokio thread in background mode). Built on first use; a
    // failure (e.g. TLS setup) is reported to every request.
    static CLIENT: Result<reqwest::Client, String> = {
        // rustls with the ring crypto provider (see Cargo.toml).
        let _ = rustls::crypto::ring::default_provider().install_default();
        reqwest::Client::builder().build().map_err(|e| error_chain(&e))
    };
}

/// The error message of a request that timed out, on every backend.
const TIMEOUT: &str = "timeout";

/// Error messages, the same on every backend.
const CLOSED: &str = "closed";

/// reqwest's timeout message is "operation timed out", somewhere in a chain
/// of causes: report it as [TIMEOUT], like the other backends.
fn req_err(e: reqwest::Error) -> String {
    if e.is_timeout() { TIMEOUT.to_string() } else { error_chain(&e) }
}

/// The request, without its timeout.
fn build(req: &Request) -> Result<reqwest::RequestBuilder, String> {
    use reqwest::header::{HeaderName, HeaderValue};
    let client = CLIENT.with(|c| c.clone())?;
    let method = reqwest::Method::from_bytes(&req.method).map_err(|e| error_chain(&e))?;
    let mut rb = client.request(method, &req.url);
    for (k, v) in &req.headers {
        let k = HeaderName::from_bytes(k).map_err(|e| error_chain(&e))?;
        let v = HeaderValue::from_bytes(v).map_err(|e| error_chain(&e))?;
        rb = rb.header(k, v);
    }
    if let Some(b) = &req.body {
        rb = rb.body(b.clone());
    }
    Ok(rb)
}

/// Every response header as "name:value\n".
fn headers_of(resp: &reqwest::Response) -> Vec<u8> {
    let mut headers = Vec::new();
    for (k, v) in resp.headers() {
        headers.extend_from_slice(k.as_str().as_bytes());
        headers.push(b':');
        headers.extend_from_slice(v.as_bytes());
        headers.push(b'\n');
    }
    headers
}

async fn perform(req: Request) -> Result<Response, String> {
    let mut rb = build(&req)?;
    if let Some(t) = req.timeout {
        // From the start of the connection to the end of the body.
        rb = rb.timeout(t);
    }
    let mut resp = rb.send().await.map_err(req_err)?;
    let status = resp.status().as_u16();
    let headers = headers_of(&resp);
    // Read the body chunk by chunk straight into a malloc'd buffer: it is
    // either copied once into an OCaml string, or handed to OCaml as is.
    let mut body = MallocBuf::new();
    if let Some(n) = resp.content_length() {
        body.reserve(n.min(1 << 30) as usize)?;
    }
    while let Some(chunk) = resp.chunk().await.map_err(req_err)? {
        body.extend(&chunk)?;
    }
    Ok(Response { status, headers, body })
}

/// Call the C callback with a result.
fn deliver(ctx: *mut c_void, cb: DoneCb, res: Result<Response, String>) -> c_int {
    match res {
        Ok(r) => {
            let (body, body_len) = r.body.into_raw();
            cb(ctx, r.status as c_int, r.headers.as_ptr(), r.headers.len(), body, body_len,
               std::ptr::null(), 0)
        }
        Err(e) => cb(ctx, 0, std::ptr::null(), 0, std::ptr::null_mut(), 0, e.as_ptr(), e.len()),
    }
}

// ---------------------------------------------------------------- local mode

thread_local! {
    // Leaked on purpose: no destructors to run at thread exit.
    static RT: &'static Runtime = Box::leak(Box::new(
        Builder::new_current_thread().enable_all().build().expect("tokio runtime")
    ));
    static LOCAL: &'static LocalSet = Box::leak(Box::new(LocalSet::new()));
    static WAKE: Rc<Notify> = Rc::new(Notify::new());
    static LOCAL_PENDING: Cell<usize> = const { Cell::new(0) };
    static RUNNING: Cell<bool> = const { Cell::new(false) };
    static STOP: Cell<bool> = const { Cell::new(false) };
}

/// Queue a task (a request or a timer) whose result goes to `cb`.
fn queue_local<F>(work: F, ctx: *mut c_void, cb: DoneCb)
where
    F: Future<Output = Result<Response, String>> + 'static,
{
    LOCAL_PENDING.with(|p| p.set(p.get() + 1));
    // `LocalSet::spawn_local` works whether or not the loop is running: the
    // task is polled the next time it is.
    LOCAL.with(|local| {
        let task = local.spawn_local(work);
        // A second task reports the result, including if the first one
        // panicked: the callback is always called exactly once.
        local.spawn_local(async move {
            let res = match task.await {
                Ok(r) => r,
                Err(e) => Err(format!("internal error: {e}")),
            };
            let stop = deliver(ctx, cb, res);
            LOCAL_PENDING.with(|p| p.set(p.get() - 1));
            if stop != 0 {
                STOP.with(|s| s.set(true));
            }
            WAKE.with(|w| w.notify_one());
        });
    });
}

/// Run local-mode requests until none is pending, or until a callback asks to
/// stop. Returns 0 on normal exit, 1 if called re-entrantly (from a callback),
/// 2 if the runtime panicked.
#[no_mangle]
pub extern "C" fn fetch_rs_run_local() -> c_int {
    if LOCAL_PENDING.with(|p| p.get()) == 0 {
        return 0;
    }
    if RUNNING.with(|r| r.replace(true)) {
        return 1;
    }
    STOP.with(|s| s.set(false));
    let res = catch_unwind(AssertUnwindSafe(|| {
        let rt = RT.with(|rt| *rt);
        let local = LOCAL.with(|l| *l);
        let wake = WAKE.with(|w| w.clone());
        rt.block_on(local.run_until(async move {
            while !STOP.with(|s| s.get()) && LOCAL_PENDING.with(|p| p.get()) > 0 {
                wake.notified().await;
            }
        }))
    }));
    RUNNING.with(|r| r.set(false));
    if res.is_ok() { 0 } else { 2 }
}

// ----------------------------------------------------------- background mode

static BACKGROUND: AtomicBool = AtomicBool::new(false);

struct Completion {
    ctx: usize, // the C-side context pointer
    cb: DoneCb,
    result: Result<Response, String>,
}

/// State shared between the OCaml thread and the tokio thread.
struct Shared {
    runtime: Handle,
    queue: Mutex<VecDeque<Completion>>,
    read_fd: c_int,  // watched by the event loop
    write_fd: c_int, // same fd as read_fd for an eventfd
}

static SHARED: OnceLock<Result<Shared, String>> = OnceLock::new();
/// Background requests started and not yet delivered to OCaml.
static BG_PENDING: AtomicUsize = AtomicUsize::new(0);

fn os_error(what: &str) -> String {
    format!("{what}: {}", std::io::Error::last_os_error())
}

/// The wakeup fd(s): an eventfd on Linux (one counter, cheaper than a pipe),
/// a non-blocking close-on-exec pipe elsewhere.
#[cfg(target_os = "linux")]
fn wakeup_fds() -> Result<(c_int, c_int), String> {
    let fd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
    if fd < 0 { Err(os_error("eventfd")) } else { Ok((fd, fd)) }
}

#[cfg(not(target_os = "linux"))]
fn wakeup_fds() -> Result<(c_int, c_int), String> {
    let mut fds = [0 as c_int; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(os_error("pipe"));
    }
    for fd in fds {
        unsafe {
            let fl = libc::fcntl(fd, libc::F_GETFL);
            let fd_fl = libc::fcntl(fd, libc::F_GETFD);
            if fl < 0 || fd_fl < 0
                || libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK) < 0
                || libc::fcntl(fd, libc::F_SETFD, fd_fl | libc::FD_CLOEXEC) < 0
            {
                return Err(os_error("fcntl"));
            }
        }
    }
    Ok((fds[0], fds[1]))
}

/// Make the fd readable (non-blocking; if a wakeup is already pending, the
/// write may fail harmlessly).
fn signal(s: &Shared) {
    let one: u64 = 1; // an eventfd needs 8 bytes; a pipe takes them too
    unsafe { libc::write(s.write_fd, &one as *const u64 as *const c_void, 8) };
}

/// Make the fd non-readable again.
fn drain(s: &Shared) {
    let mut buf = [0u8; 64];
    while unsafe { libc::read(s.read_fd, buf.as_mut_ptr() as *mut c_void, buf.len()) } > 0 {}
}

fn start() -> Result<Shared, String> {
    let (read_fd, write_fd) = wakeup_fds()?;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("fetch-tokio".into())
        .spawn(move || match Builder::new_current_thread().enable_all().build() {
            Ok(rt) => {
                let _ = tx.send(Ok(rt.handle().clone()));
                // Run spawned tasks until the process exits.
                rt.block_on(std::future::pending::<()>());
            }
            Err(e) => {
                let _ = tx.send(Err(format!("tokio runtime: {e}")));
            }
        })
        .map_err(|e| format!("thread: {e}"))?;
    let runtime = rx.recv().map_err(|e| format!("thread: {e}"))??;
    Ok(Shared { runtime, queue: Mutex::new(VecDeque::new()), read_fd, write_fd })
}

fn shared() -> Result<&'static Shared, String> {
    SHARED.get_or_init(start).as_ref().map_err(|e| e.clone())
}

/// Called on the tokio thread when a request is done.
fn complete(s: &Shared, c: Completion) {
    let was_empty = {
        let mut q = s.queue.lock().unwrap_or_else(|e| e.into_inner());
        let was_empty = q.is_empty();
        q.push_back(c);
        was_empty
    };
    // One wakeup per batch: the dispatcher drains the whole queue.
    if was_empty {
        signal(s);
    }
}

/// Queue a task (a request or a timer) whose result goes to `cb`.
fn queue_background<F>(work: F, ctx: *mut c_void, cb: DoneCb) -> Result<(), String>
where
    F: Future<Output = Result<Response, String>> + Send + 'static,
{
    let s = shared()?;
    let ctx = ctx as usize;
    BG_PENDING.fetch_add(1, Ordering::SeqCst);
    let task = s.runtime.spawn(work);
    // A second task reports the result, including if the first one panicked:
    // the callback is always called exactly once.
    s.runtime.spawn(async move {
        let result = match task.await {
            Ok(r) => r,
            Err(e) => Err(format!("internal error: {e}")),
        };
        complete(s, Completion { ctx, cb, result });
    });
    Ok(())
}

/// Switch to background mode for the requests started from now on (the
/// background thread itself starts with the first such request).
#[no_mangle]
pub extern "C" fn fetch_rs_use_background() {
    BACKGROUND.store(true, Ordering::SeqCst);
}

/// Switch to background mode and return the fd to watch (starting the
/// background thread), or -1 if it could not be started.
#[no_mangle]
pub extern "C" fn fetch_rs_fd() -> c_int {
    fetch_rs_use_background();
    match shared() {
        Ok(s) => s.read_fd,
        Err(_) => -1,
    }
}

/// Deliver every completed background request, on the calling (OCaml) thread.
/// Never blocks. Returns 0, or 1 if a callback asked to stop (the remaining
/// completions stay queued and the fd is signalled again).
#[no_mangle]
pub extern "C" fn fetch_rs_dispatch() -> c_int {
    let Some(Ok(s)) = SHARED.get() else { return 0 };
    // Drain the wakeup first: anything completed after this point signals
    // again (or is picked up by the loop below).
    drain(s);
    loop {
        // One completion at a time, without holding the lock while OCaml
        // runs (callbacks may start requests or dispatch again).
        let next = s.queue.lock().unwrap_or_else(|e| e.into_inner()).pop_front();
        let Some(c) = next else { return 0 };
        BG_PENDING.fetch_sub(1, Ordering::SeqCst);
        if deliver(c.ctx as *mut c_void, c.cb, c.result) != 0 {
            if !s.queue.lock().unwrap_or_else(|e| e.into_inner()).is_empty() {
                signal(s);
            }
            return 1;
        }
    }
}

/// Block until a background completion may be available. Call it with the
/// OCaml runtime lock released.
#[no_mangle]
pub extern "C" fn fetch_rs_wait() {
    let Some(Ok(s)) = SHARED.get() else { return };
    let mut p = libc::pollfd { fd: s.read_fd, events: libc::POLLIN, revents: 0 };
    loop {
        let r = unsafe { libc::poll(&mut p, 1, -1) };
        if r >= 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return;
        }
    }
}

/// Background requests started and not yet delivered.
#[no_mangle]
pub extern "C" fn fetch_rs_bg_pending() -> usize {
    BG_PENDING.load(Ordering::SeqCst)
}

// ------------------------------------------------------------------ requests

unsafe fn bytes<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, len)
    }
}

/// Queue a task in the current mode. Returns 0 on success, 1 if it could not
/// be queued (`cb` is then never called).
fn queue<F>(work: F, ctx: *mut c_void, cb: DoneCb) -> c_int
where
    F: Future<Output = Result<Response, String>> + Send + 'static,
{
    let queued = catch_unwind(AssertUnwindSafe(|| {
        if BACKGROUND.load(Ordering::SeqCst) {
            queue_background(work, ctx, cb)
        } else {
            queue_local(work, ctx, cb);
            Ok(())
        }
    }));
    match queued {
        Ok(Ok(())) => 0,
        _ => 1,
    }
}

/// Queue a request (in the current mode). `timeout` is in seconds; negative or
/// NaN means none. All input buffers are copied before returning. `cb` is called exactly once with `ctx`: from `fetch_rs_run_local`
/// in local mode, from `fetch_rs_dispatch` in background mode. Returns 0 on
/// success, non-zero if the request could not be queued (`cb` is then never
/// called).
///
/// # Safety
/// Pointers must be valid for the given lengths; `headers` must point to
/// `n_headers` valid entries.
#[no_mangle]
pub unsafe extern "C" fn fetch_rs_request(
    method: *const u8,
    method_len: usize,
    url: *const u8,
    url_len: usize,
    headers: *const FetchHeader,
    n_headers: usize,
    body: *const u8,
    body_len: usize,
    has_body: c_int,
    timeout: f64,
    ctx: *mut c_void,
    cb: DoneCb,
) -> c_int {
    let req = request_of(method, method_len, url, url_len, headers, n_headers, body, body_len, has_body, timeout);
    queue(perform(req), ctx, cb)
}

/// Copy a request's C arguments.
#[allow(clippy::too_many_arguments)]
unsafe fn request_of(
    method: *const u8,
    method_len: usize,
    url: *const u8,
    url_len: usize,
    headers: *const FetchHeader,
    n_headers: usize,
    body: *const u8,
    body_len: usize,
    has_body: c_int,
    timeout: f64,
) -> Request {
    Request {
        method: bytes(method, method_len).to_vec(),
        url: String::from_utf8_lossy(bytes(url, url_len)).into_owned(),
        headers: (0..n_headers)
            .map(|i| {
                let h = &*headers.add(i);
                (bytes(h.name, h.name_len).to_vec(), bytes(h.value, h.value_len).to_vec())
            })
            .collect(),
        body: (has_body != 0).then(|| bytes(body, body_len).to_vec()),
        // (a duration too large to represent is no timeout)
        timeout: if timeout >= 0. { Duration::try_from_secs_f64(timeout).ok() } else { None },
    }
}

/// Timers not yet fired or cancelled, by id: notifying one cancels it.
static TIMERS: OnceLock<Mutex<HashMap<u64, Arc<Notify>>>> = OnceLock::new();
static NEXT_TIMER: AtomicU64 = AtomicU64::new(0);

fn timers() -> std::sync::MutexGuard<'static, HashMap<u64, Arc<Notify>>> {
    TIMERS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// Queue a timer: `cb` is called (as for a request, with status 0 and an
/// empty response) once `seconds` have passed, counted from now even in
/// local mode, where the task only starts being polled when the loop runs.
/// Negative or NaN values count as 0; too large ones (infinity) mean ~30
/// years. Returns the timer's id (for `fetch_rs_cancel_timer`), or -1 if it
/// could not be queued.
#[no_mangle]
pub extern "C" fn fetch_rs_after(seconds: f64, ctx: *mut c_void, cb: DoneCb) -> i64 {
    const MAX: Duration = Duration::from_secs(30 * 365 * 24 * 3600);
    let d = if seconds > 0. {
        Duration::try_from_secs_f64(seconds).unwrap_or(MAX).min(MAX)
    } else {
        Duration::ZERO
    };
    let deadline = tokio::time::Instant::now() + d;
    let id = NEXT_TIMER.fetch_add(1, Ordering::Relaxed);
    let cancel = Arc::new(Notify::new());
    timers().insert(id, cancel.clone());
    let r = queue(
        async move {
            // Ok: notified before the deadline, i.e. cancelled
            let cancelled = tokio::time::timeout_at(deadline, cancel.notified()).await.is_ok();
            timers().remove(&id);
            if cancelled {
                Err("cancelled".to_string())
            } else {
                Ok(Response { status: 0, headers: Vec::new(), body: MallocBuf::new() })
            }
        },
        ctx,
        cb,
    );
    if r == 0 {
        id as i64
    } else {
        timers().remove(&id);
        -1
    }
}

/// Cancel a timer: its task ends at once, and `cb` is still called (with an
/// error), as for every queued task. No effect if the timer has already
/// fired (its callback may then still be pending delivery).
#[no_mangle]
pub extern "C" fn fetch_rs_cancel_timer(id: u64) {
    if let Some(n) = timers().remove(&id) {
        // stores a permit if the task has not started waiting yet
        n.notify_one();
    }
}

// ------------------------------------------------------------------- streams
//
// A stream is a response whose body stays here, read one chunk at a time:
// `fetch_rs_stream_open` delivers the status and headers (like a request,
// with an empty body), then each `fetch_rs_stream_read` delivers one chunk
// (status 1) or the end of the body (status 0). Both are tasks, delivered
// like requests. A stream is removed from the table, and its connection
// released, when its body ends, on an error, or on `fetch_rs_stream_close`.

struct Stream {
    resp: tokio::sync::Mutex<Option<reqwest::Response>>,
    /// Notified by `fetch_rs_stream_close`: wakes the task waiting on the
    /// stream (opening it, or reading a chunk), if any.
    close: Notify,
}

static STREAMS: OnceLock<Mutex<HashMap<u64, Arc<Stream>>>> = OnceLock::new();
static NEXT_STREAM: AtomicU64 = AtomicU64::new(0);

fn streams() -> std::sync::MutexGuard<'static, HashMap<u64, Arc<Stream>>> {
    STREAMS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// `fut`, unless `close` is notified first (then `None`).
async fn unless_closed<T>(fut: impl Future<Output = T>, close: &Notify) -> Option<T> {
    let mut fut = std::pin::pin!(fut);
    let mut closed = std::pin::pin!(close.notified());
    std::future::poll_fn(|cx| {
        if let std::task::Poll::Ready(v) = fut.as_mut().poll(cx) {
            return std::task::Poll::Ready(Some(v));
        }
        closed.as_mut().poll(cx).map(|()| None)
    })
    .await
}

/// `fut`, failing with [TIMEOUT] if `deadline` comes first.
async fn before<T>(deadline: Option<tokio::time::Instant>, fut: impl Future<Output = Result<T, String>>) -> Result<T, String> {
    match deadline {
        None => fut.await,
        Some(d) => tokio::time::timeout_at(d, fut).await.unwrap_or_else(|_| Err(TIMEOUT.to_string())),
    }
}

/// A deadline `seconds` from now; negative or NaN: none.
fn deadline(seconds: f64) -> Option<tokio::time::Instant> {
    if seconds >= 0. {
        Duration::try_from_secs_f64(seconds).ok().map(|d| tokio::time::Instant::now() + d)
    } else {
        None
    }
}

fn empty(status: u16) -> Response {
    Response { status, headers: Vec::new(), body: MallocBuf::new() }
}

/// Open a stream: send the request, and deliver the status and headers to
/// `cb` (with an empty body). `timeout` (seconds, negative for none) bounds
/// the wait for the headers only. Returns the stream's id, or -1 if the
/// request could not be queued.
///
/// # Safety
/// As for `fetch_rs_request`.
#[no_mangle]
pub unsafe extern "C" fn fetch_rs_stream_open(
    method: *const u8,
    method_len: usize,
    url: *const u8,
    url_len: usize,
    headers: *const FetchHeader,
    n_headers: usize,
    body: *const u8,
    body_len: usize,
    has_body: c_int,
    timeout: f64,
    ctx: *mut c_void,
    cb: DoneCb,
) -> i64 {
    let req = request_of(method, method_len, url, url_len, headers, n_headers, body, body_len, has_body, -1.);
    let deadline = deadline(timeout);
    let id = NEXT_STREAM.fetch_add(1, Ordering::Relaxed);
    let stream = Arc::new(Stream { resp: tokio::sync::Mutex::new(None), close: Notify::new() });
    streams().insert(id, stream.clone());
    let work = async move {
        let send = before(deadline, async { build(&req)?.send().await.map_err(req_err) });
        let r = match unless_closed(send, &stream.close).await {
            None => Err(CLOSED.to_string()),
            Some(Ok(resp)) => {
                let head = Response { status: resp.status().as_u16(), headers: headers_of(&resp), body: MallocBuf::new() };
                *stream.resp.lock().await = Some(resp);
                Ok(head)
            }
            Some(Err(e)) => Err(e),
        };
        if r.is_err() {
            streams().remove(&id);
        }
        r
    };
    if queue(work, ctx, cb) == 0 {
        id as i64
    } else {
        streams().remove(&id);
        -1
    }
}

/// Read the next chunk of a stream: `cb` gets it as the body, with status 1,
/// or status 0 and an empty body at the end; or an error ("timeout" if
/// `timeout` seconds pass first, "closed" if the stream was closed). After
/// the end or an error, the stream is closed. One read at a time per stream.
/// Returns 0, or non-zero if the read could not be queued.
#[no_mangle]
pub extern "C" fn fetch_rs_stream_read(id: u64, timeout: f64, ctx: *mut c_void, cb: DoneCb) -> c_int {
    let deadline = deadline(timeout);
    let Some(stream) = streams().get(&id).cloned() else {
        return queue(async { Err(CLOSED.to_string()) }, ctx, cb);
    };
    queue(
        async move {
            let mut resp = stream.resp.lock().await;
            let Some(r) = resp.as_mut() else { return Err(CLOSED.to_string()) };
            let read = before(deadline, async { r.chunk().await.map_err(req_err) });
            let res = match unless_closed(read, &stream.close).await {
                None => Err(CLOSED.to_string()),
                Some(Ok(Some(chunk))) => {
                    let mut body = MallocBuf::new();
                    body.extend(&chunk).map(|()| Response { status: 1, headers: Vec::new(), body })
                }
                Some(Ok(None)) => Ok(empty(0)),
                Some(Err(e)) => Err(e),
            };
            if !matches!(res, Ok(Response { status: 1, .. })) {
                // end of the body, or an error: release the connection
                *resp = None;
                streams().remove(&id);
            }
            res
        },
        ctx,
        cb,
    )
}

/// Close a stream: a pending open or read fails with "closed", and the
/// connection is released. No effect on a stream already closed or ended.
#[no_mangle]
pub extern "C" fn fetch_rs_stream_close(id: u64) {
    if let Some(stream) = streams().remove(&id) {
        // stores a permit if no task is waiting on the stream yet
        stream.close.notify_one();
        if let Ok(mut resp) = stream.resp.try_lock() {
            *resp = None;
        }
    }
}
