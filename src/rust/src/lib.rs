use std::cell::Cell;
use std::collections::{HashMap, VecDeque};
use std::ffi::{c_int, c_void};
use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, AtomicUsize, Ordering};
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

struct MallocBuf {
    ptr: *mut u8,
    len: usize,
    cap: usize,
}

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
    headers: Vec<u8>,
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

    static CLIENT: Result<reqwest::Client, String> = {

        let _ = rustls::crypto::ring::default_provider().install_default();
        reqwest::Client::builder().build().map_err(|e| error_chain(&e))
    };
}

const TIMEOUT: &str = "timeout";

const CLOSED: &str = "closed";

fn req_err(e: reqwest::Error) -> String {
    if e.is_timeout() { TIMEOUT.to_string() } else { error_chain(&e) }
}

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

        rb = rb.timeout(t);
    }
    let mut resp = rb.send().await.map_err(req_err)?;
    let status = resp.status().as_u16();
    let headers = headers_of(&resp);

    let mut body = MallocBuf::new();
    if let Some(n) = resp.content_length() {
        body.reserve(n.min(1 << 30) as usize)?;
    }
    while let Some(chunk) = resp.chunk().await.map_err(req_err)? {
        body.extend(&chunk)?;
    }
    Ok(Response { status, headers, body })
}

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

thread_local! {

    static RT: &'static Runtime = Box::leak(Box::new(
        Builder::new_current_thread().enable_all().build().expect("tokio runtime")
    ));
    static LOCAL: &'static LocalSet = Box::leak(Box::new(LocalSet::new()));
    static WAKE: Rc<Notify> = Rc::new(Notify::new());
    static LOCAL_PENDING: Cell<usize> = const { Cell::new(0) };
    static RUNNING: Cell<bool> = const { Cell::new(false) };
    static STOP: Cell<bool> = const { Cell::new(false) };
}

fn queue_local<F>(work: F, ctx: *mut c_void, cb: DoneCb)
where
    F: Future<Output = Result<Response, String>> + 'static,
{
    LOCAL_PENDING.with(|p| p.set(p.get() + 1));

    LOCAL.with(|local| {
        let task = local.spawn_local(work);

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

struct RawFd(c_int);

impl std::os::fd::AsRawFd for RawFd {
    fn as_raw_fd(&self) -> c_int {
        self.0
    }
}

#[no_mangle]
pub extern "C" fn fetch_rs_run_local_until(fd: c_int) -> c_int {
    if LOCAL_PENDING.with(|p| p.get()) == 0 {
        return 3;
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

            let other = if fd >= 0 {

                unsafe {
                    tokio::io::unix::AsyncFd::register_with_interest(RawFd(fd), tokio::io::Interest::READABLE).ok()
                }
            } else {
                None
            };
            while !STOP.with(|s| s.get()) && LOCAL_PENDING.with(|p| p.get()) > 0 {
                match &other {
                    Some(other) => tokio::select! {
                        _ = wake.notified() => {}
                        r = other.readable() => if r.is_ok() { break },
                    },
                    None => wake.notified().await,
                }
            }
        }))
    }));
    RUNNING.with(|r| r.set(false));
    if res.is_ok() { 0 } else { 2 }
}

static BACKGROUND: AtomicBool = AtomicBool::new(false);

struct Completion {
    ctx: usize,
    cb: DoneCb,
    result: Result<Response, String>,
}

struct Shared {
    runtime: Handle,
    queue: Mutex<VecDeque<Completion>>,
    read_fd: c_int,
    write_fd: c_int,
}

static SHARED: OnceLock<Result<Shared, String>> = OnceLock::new();

static BG_PENDING: AtomicUsize = AtomicUsize::new(0);

fn os_error(what: &str) -> String {
    format!("{what}: {}", std::io::Error::last_os_error())
}

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

static WAKE_FD: AtomicI32 = AtomicI32::new(-1);

#[no_mangle]
pub extern "C" fn fetch_rs_set_wake_fd(fd: c_int) {
    WAKE_FD.store(fd, Ordering::SeqCst);
}

fn signal(s: &Shared) {
    let one: u64 = 1;
    let fd = match WAKE_FD.load(Ordering::SeqCst) {
        -1 => s.write_fd,
        fd => fd,
    };
    unsafe { libc::write(fd, &one as *const u64 as *const c_void, 8) };
}

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

fn complete(s: &Shared, c: Completion) {
    let was_empty = {
        let mut q = s.queue.lock().unwrap_or_else(|e| e.into_inner());
        let was_empty = q.is_empty();
        q.push_back(c);
        was_empty
    };

    if was_empty {
        signal(s);
    }
}

fn queue_background<F>(work: F, ctx: *mut c_void, cb: DoneCb) -> Result<(), String>
where
    F: Future<Output = Result<Response, String>> + Send + 'static,
{
    let s = shared()?;
    let ctx = ctx as usize;
    BG_PENDING.fetch_add(1, Ordering::SeqCst);
    let task = s.runtime.spawn(work);

    s.runtime.spawn(async move {
        let result = match task.await {
            Ok(r) => r,
            Err(e) => Err(format!("internal error: {e}")),
        };
        complete(s, Completion { ctx, cb, result });
    });
    Ok(())
}

#[no_mangle]
pub extern "C" fn fetch_rs_use_background() {
    BACKGROUND.store(true, Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn fetch_rs_dispatch() -> c_int {
    let Some(Ok(s)) = SHARED.get() else { return 0 };

    drain(s);
    loop {

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

unsafe fn bytes<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, len)
    }
}

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

        timeout: if timeout >= 0. { Duration::try_from_secs_f64(timeout).ok() } else { None },
    }
}

static TIMERS: OnceLock<Mutex<HashMap<u64, Arc<Notify>>>> = OnceLock::new();
static NEXT_TIMER: AtomicU64 = AtomicU64::new(0);

fn timers() -> std::sync::MutexGuard<'static, HashMap<u64, Arc<Notify>>> {
    TIMERS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

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

#[no_mangle]
pub extern "C" fn fetch_rs_cancel_timer(id: u64) {
    if let Some(n) = timers().remove(&id) {

        n.notify_one();
    }
}

struct Stream {
    resp: tokio::sync::Mutex<Option<reqwest::Response>>,

    close: Notify,
}

static STREAMS: OnceLock<Mutex<HashMap<u64, Arc<Stream>>>> = OnceLock::new();
static NEXT_STREAM: AtomicU64 = AtomicU64::new(0);

fn streams() -> std::sync::MutexGuard<'static, HashMap<u64, Arc<Stream>>> {
    STREAMS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

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

async fn before<T>(deadline: Option<tokio::time::Instant>, fut: impl Future<Output = Result<T, String>>) -> Result<T, String> {
    match deadline {
        None => fut.await,
        Some(d) => tokio::time::timeout_at(d, fut).await.unwrap_or_else(|_| Err(TIMEOUT.to_string())),
    }
}

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

                *resp = None;
                streams().remove(&id);
            }
            res
        },
        ctx,
        cb,
    )
}

#[no_mangle]
pub extern "C" fn fetch_rs_stream_close(id: u64) {
    if let Some(stream) = streams().remove(&id) {

        stream.close.notify_one();
        if let Ok(mut resp) = stream.resp.try_lock() {
            *resp = None;
        }
    }
}
