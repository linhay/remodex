// FILE: qr.test.js
// Purpose: Verifies terminal QR output can be suppressed while still exposing a pasteable pairing code.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, qrcode-terminal, ../src/qr

const test = require("node:test");
const assert = require("node:assert/strict");
const qrcode = require("qrcode-terminal");
const { printQR } = require("../src/qr");

const PAIRING_PAYLOAD = {
  v: 2,
  relay: "wss://relay.example/relay",
  relayAuthKey: "secret-key",
  sessionId: "session-123",
  macDeviceId: "mac-123",
  macIdentityPublicKey: "public-key",
  expiresAt: Date.UTC(2026, 2, 14, 15, 0, 0),
};

test("printQR renders the terminal QR by default", (t) => {
  const generateCalls = [];
  const logLines = [];
  const originalGenerate = qrcode.generate;
  const originalLog = console.log;

  t.after(() => {
    qrcode.generate = originalGenerate;
    console.log = originalLog;
    delete process.env.REMODEX_QR_MODE;
    delete process.env.REMODEX_PRINT_PAIRING_CODE;
  });

  qrcode.generate = (payload, options) => {
    generateCalls.push({ payload, options });
  };
  console.log = (line = "") => {
    logLines.push(line);
  };

  printQR(PAIRING_PAYLOAD);

  assert.equal(generateCalls.length, 1);
  assert.equal(generateCalls[0].payload, JSON.stringify(PAIRING_PAYLOAD));
  assert.deepEqual(generateCalls[0].options, { small: true });
  assert.equal(logLines.some((line) => String(line).includes("Pairing Code:")), false);
});

test("printQR can suppress QR output and print a pasteable pairing code", (t) => {
  const generateCalls = [];
  const logLines = [];
  const originalGenerate = qrcode.generate;
  const originalLog = console.log;

  t.after(() => {
    qrcode.generate = originalGenerate;
    console.log = originalLog;
    delete process.env.REMODEX_QR_MODE;
    delete process.env.REMODEX_PRINT_PAIRING_CODE;
  });

  process.env.REMODEX_QR_MODE = "none";

  qrcode.generate = (payload, options) => {
    generateCalls.push({ payload, options });
  };
  console.log = (line = "") => {
    logLines.push(line);
  };

  printQR(PAIRING_PAYLOAD);

  assert.equal(generateCalls.length, 0);
  assert.equal(logLines.some((line) => String(line).includes("Pairing Code:")), true);
  assert.equal(logLines.some((line) => String(line).includes(JSON.stringify(PAIRING_PAYLOAD))), true);
});
