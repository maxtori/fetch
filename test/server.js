// Test server: node server.js [PORT [--exit-with-stdin]] (default port 8765,
// 0 = any free port).
// Prints "listening PORT" once ready. /delay/N answers after N seconds,
// /status/N with status N. The body echoes the request as JSON, except:
// - /stream/N/MS: N chunks "chunk I\n", one every MS milliseconds;
// - /stall: one chunk "first\n", then nothing (the response never ends).
const http = require("http");
const server = http.createServer((req, res) => {
  let body = [];
  req.on("data", c => body.push(c));
  req.on("end", () => {
    const sm = req.url.match(/^\/stream\/(\d+)\/(\d+)/);
    if (sm) {
      res.setHeader("content-type", "text/plain");
      let i = 0;
      const next = () => {
        if (i === +sm[1]) return res.end();
        res.write(`chunk ${i++}\n`);
        setTimeout(next, +sm[2]);
      };
      return next();
    }
    if (req.url === "/stall") {
      res.setHeader("content-type", "text/plain");
      res.flushHeaders();
      return res.write("first\n");
    }
    const m = req.url.match(/^\/delay\/(\d+)/);
    const delay = m ? +m[1] * 1000 : 0;
    const st = req.url.match(/^\/status\/(\d+)/);
    if (st) res.statusCode = +st[1];
    setTimeout(() => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ method: req.method, url: req.url, body: Buffer.concat(body).toString(), ct: req.headers["content-type"] || "" }));
    }, delay);
  });
});
server.listen(+(process.argv[2] ?? 8765), () => console.log("listening " + server.address().port));
// --exit-with-stdin: exit when stdin closes, i.e. when the parent process
// (a test started with Test_server.start) is gone.
if (process.argv.includes("--exit-with-stdin")) {
  process.stdin.on("end", () => process.exit(0));
  process.stdin.resume();
}
