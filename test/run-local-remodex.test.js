// FILE: run-local-remodex.test.js
// Purpose: Verifies the local launcher picks the correct relay bind host for LAN and Cloudflare modes.
// Layer: Integration-style script test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, node:child_process

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");

const ROOT = "/Users/linhey/Desktop/Dockers/remodex";
const SCRIPT = `${ROOT}/run-local-remodex.sh`;

function runScript(args) {
  return runScriptWithEnv(args, {
    REMODEX_PUBLIC_RELAY_URL: "",
  });
}

function runScriptWithEnv(args, envOverrides) {
  return execFileSync(SCRIPT, args, {
    cwd: ROOT,
    encoding: "utf8",
    env: {
      ...process.env,
      REMODEX_RELAY_KEY: "test-key",
      REMODEX_PUBLIC_RELAY_URL: "",
      REMODEX_ENV_FILE: "/tmp/remodex-test-missing.env",
      ...envOverrides,
    },
  });
}

test("LAN mode binds relay on 0.0.0.0 in dry-run output", () => {
  const output = runScript(["--dry-run"]);
  assert.match(output, /HOST=0\.0\.0\.0/);
  assert.match(output, /ws:\/\/.*:8787\/relay/);
});

test("Cloudflare mode binds relay on 127.0.0.1 in dry-run output", () => {
  const output = runScript(["--cloudflare", "--dry-run"]);
  assert.match(output, /HOST=127\.0\.0\.1/);
  assert.match(output, /cloudflared tunnel --protocol http2 --url http:\/\/127\.0\.0\.1:8787/);
});

test("custom relay URL skips cloudflared and uses the fixed public relay", () => {
  const output = runScript([
    "--relay-url",
    "wss://relay.example.com/relay",
    "--dry-run",
  ]);
  assert.doesNotMatch(output, /cloudflared tunnel/);
  assert.match(output, /REMODEX_RELAY=wss:\/\/relay\.example\.com\/relay/);
});

test("named tunnel token file starts cloudflared with token file and fixed relay URL", () => {
  const output = runScript([
    "--relay-url",
    "wss://relay.example.com/relay",
    "--cloudflared-token-file",
    "/tmp/remodex.token",
    "--dry-run",
  ]);
  assert.match(output, /cloudflared tunnel --protocol http2 --url http:\/\/127\.0\.0\.1:8787 run --token-file \/tmp\/remodex\.token/);
  assert.match(output, /REMODEX_RELAY=wss:\/\/relay\.example\.com\/relay/);
  assert.doesNotMatch(output, /trycloudflare/);
});

test("named tunnel token file requires a fixed public relay URL", () => {
  assert.throws(
    () => runScriptWithEnv(["--cloudflared-token-file", "/tmp/remodex.token", "--dry-run"], {
      REMODEX_PUBLIC_RELAY_URL: "",
    }),
    /REMODEX_PUBLIC_RELAY_URL is required/
  );
});
