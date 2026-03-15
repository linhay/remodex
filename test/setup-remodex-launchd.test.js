// FILE: setup-remodex-launchd.test.js
// Purpose: Verifies launchd installer dry-run output and required argument validation.
// Layer: Integration-style script test
// Depends on: node:test, node:assert/strict, node:child_process, node:os, node:path, node:fs

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const os = require("node:os");
const path = require("node:path");
const fs = require("node:fs");

const ROOT = "/Users/linhey/Desktop/Dockers/remodex";
const SCRIPT = `${ROOT}/setup-remodex-launchd.sh`;

function runScript(args, envOverrides = {}) {
  return execFileSync(SCRIPT, args, {
    cwd: ROOT,
    encoding: "utf8",
    env: {
      ...process.env,
      ...envOverrides,
    },
  });
}

test("dry-run prints plist content with never-expire pairing and named tunnel args", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-launchd-test-"));
  const output = runScript([
    "--token-file", "/tmp/remodex.token",
    "--public-relay-url", "wss://relay.section.trade/relay",
    "--relay-key", "test-key",
    "--agent-dir", tempDir,
    "--dry-run",
  ]);

  assert.match(output, /REMODEX_PAIRING_TTL_MS/);
  assert.match(output, /<string>never<\/string>/);
  assert.match(output, /<key>PATH<\/key>/);
  assert.match(output, /--cloudflared-token-file/);
  assert.match(output, /--relay-url/);
  assert.match(output, /--qr/);
  assert.match(output, /<string>none<\/string>/);
  assert.match(output, /Dry-run: would write plist to /);
  assert.ok(output.includes(path.join(tempDir, "com.linhay.remodex.autostart.plist")));
});

test("missing required arguments fails with clear message", () => {
  assert.throws(
    () => runScript(["--dry-run"], {
      REMODEX_CLOUDFLARED_TOKEN_FILE: "",
      REMODEX_PUBLIC_RELAY_URL: "",
      REMODEX_RELAY_KEY: "",
    }),
    /--token-file is required/
  );
});
