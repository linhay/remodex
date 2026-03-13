// FILE: local-relay.test.js
// Purpose: Verifies CLI argument parsing and the embedded relay server used by TryCloudflare mode.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ws, ../src/cli-options, ../src/local-relay

const test = require("node:test");
const assert = require("node:assert/strict");
const WebSocket = require("ws");

const { parseCliArgs } = require("../src/cli-options");
const {
  createTunnelLaunchError,
  extractTryCloudflareUrl,
  getCloudflaredInstallHint,
  startLocalRelayServer,
} = require("../src/local-relay");

test("parseCliArgs reads TryCloudflare flags for `up`", () => {
  const result = parseCliArgs(["up", "--trycloudflare", "--trycloudflare-port", "8787"]);

  assert.equal(result.command, "up");
  assert.equal(result.options.tryCloudflare, true);
  assert.equal(result.options.tryCloudflarePort, 8787);
  assert.deepEqual(result.positionals, []);
});

test("parseCliArgs ignores a bare `--` separator from npm-style script forwarding", () => {
  const result = parseCliArgs(["up", "--", "--trycloudflare"]);

  assert.equal(result.command, "up");
  assert.equal(result.options.tryCloudflare, true);
});

test("parseCliArgs rejects unknown options", () => {
  assert.throws(
    () => parseCliArgs(["up", "--nope"]),
    /Unknown option: --nope/
  );
});

test("parseCliArgs rejects TryCloudflare options for non-up commands", () => {
  assert.throws(
    () => parseCliArgs(["resume", "--trycloudflare"]),
    /--trycloudflare is only supported with `remodex up`/
  );
  assert.throws(
    () => parseCliArgs(["watch", "--trycloudflare-port", "8787"]),
    /--trycloudflare-port is only supported with `remodex up`/
  );
});

test("parseCliArgs requires --trycloudflare when a TryCloudflare port is provided", () => {
  assert.throws(
    () => parseCliArgs(["up", "--trycloudflare-port", "8787"]),
    /--trycloudflare-port requires --trycloudflare/
  );
});

test("parseCliArgs rejects out-of-range TryCloudflare ports", () => {
  assert.throws(
    () => parseCliArgs(["up", "--trycloudflare", "--trycloudflare-port", "70000"]),
    /expects an integer between 0 and 65535/
  );
});

test("extractTryCloudflareUrl reads the public quick tunnel URL from logs", () => {
  const line = "INF | Your quick Tunnel has been created! Visit it at https://alpha-beta.trycloudflare.com";
  assert.equal(
    extractTryCloudflareUrl(line),
    "https://alpha-beta.trycloudflare.com"
  );
});

test("createTunnelLaunchError explains how to install cloudflared when it is missing", () => {
  const error = createTunnelLaunchError("cloudflared", {
    code: "ENOENT",
    message: "spawn cloudflared ENOENT",
  }, "darwin");

  assert.match(error.message, /requires `cloudflared` to be installed/);
  assert.match(error.message, /brew install cloudflared/);
});

test("getCloudflaredInstallHint provides Linux-safe guidance without macOS-specific commands", () => {
  const hint = getCloudflaredInstallHint("linux");

  assert.match(hint, /Linux instructions/);
  assert.match(hint, /developers\.cloudflare\.com\/tunnel\/setup/);
  assert.doesNotMatch(hint, /brew install cloudflared/);
});

test("startLocalRelayServer forwards messages between the Mac and iPhone roles", async () => {
  const relay = await startLocalRelayServer();
  const sessionUrl = `ws://127.0.0.1:${relay.port}/relay/test-session`;
  const mac = new WebSocket(sessionUrl, {
    headers: { "x-role": "mac" },
  });
  const iphone = new WebSocket(sessionUrl, {
    headers: { "x-role": "iphone" },
  });

  await Promise.all([
    onceOpen(mac),
    onceOpen(iphone),
  ]);

  const forwardedText = await new Promise((resolve, reject) => {
    iphone.once("message", (payload) => resolve(payload.toString("utf8")));
    iphone.once("error", reject);
    mac.send("hello-through-local-relay");
  });

  assert.equal(forwardedText, "hello-through-local-relay");

  mac.close();
  iphone.close();
  await relay.close();
});

function onceOpen(socket) {
  return new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
}
