// FILE: run-local-remodex.test.js
// Purpose: Verifies the repo-local launcher resolves LAN relay config without starting real processes.
// Layer: Integration test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, node:child_process, node:path

const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");
const scriptPath = path.join(repoRoot, "run-local-remodex.sh");

function runLauncher({ args = [], env = {} } = {}) {
  return spawnSync("bash", [scriptPath, ...args], {
    cwd: repoRoot,
    env: {
      ...process.env,
      ...env,
    },
    encoding: "utf8",
  });
}

test("dry-run resolves an explicit LAN hostname into REMODEX_RELAY", () => {
  const result = runLauncher({
    args: ["--dry-run", "--hostname", "studio-mac.local", "--port", "9100"],
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Relay URL\s+: ws:\/\/studio-mac\.local:9100\/relay/);
  assert.match(result.stdout, /Dry run: would start embedded relay on 0\.0\.0\.0:9100/);
  assert.match(result.stdout, /Dry run: REMODEX_RELAY=ws:\/\/studio-mac\.local:9100\/relay node \.\/bin\/remodex\.js up/);
});

test("dry-run skips the embedded relay when RELAY_URL is provided", () => {
  const result = runLauncher({
    args: ["--dry-run"],
    env: {
      RELAY_URL: "ws://192.168.10.114:9001/relay",
    },
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Relay URL\s+: ws:\/\/192\.168\.10\.114:9001\/relay/);
  assert.match(result.stdout, /would skip embedded relay because RELAY_URL is set/);
});
