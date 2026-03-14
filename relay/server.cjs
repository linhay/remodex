const http = require("http");
const { WebSocketServer } = require("ws");
const { setupRelay, getRelayStats } = require("./relay-node.cjs");

const port = Number.parseInt(process.env.PORT || "8787", 10);
const host = process.env.HOST || "127.0.0.1";

const server = http.createServer((req, res) => {
  if (req.url === "/" || req.url === "/health") {
    const payload = JSON.stringify({
      ok: true,
      service: "remodex-relay",
      websocketPath: "/relay/:sessionId",
      relayAuthEnabled: Boolean(process.env.REMODEX_RELAY_KEY),
      ...getRelayStats(),
    });

    res.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "content-length": Buffer.byteLength(payload),
    });
    res.end(payload);
    return;
  }

  res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
  res.end("Not Found");
});

const wss = new WebSocketServer({ server });
setupRelay(wss);

server.listen(port, host, () => {
  console.log(`[relay] listening on http://${host}:${port}`);
});

function shutdown(signal) {
  console.log(`[relay] received ${signal}, shutting down`);
  wss.close(() => {
    server.close(() => {
      process.exit(0);
    });
  });

  setTimeout(() => process.exit(1), 5_000).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
