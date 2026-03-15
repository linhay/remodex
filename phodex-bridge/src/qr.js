// FILE: qr.js
// Purpose: Prints the pairing QR payload that the iPhone scanner expects.
// Layer: CLI helper
// Exports: printQR
// Depends on: qrcode-terminal

const qrcode = require("qrcode-terminal");

function printQR(pairingPayload) {
  const payload = JSON.stringify(pairingPayload);
  const qrMode = readQrMode();
  const shouldPrintPairingCode =
    qrMode === "none" || process.env.REMODEX_PRINT_PAIRING_CODE === "true";

  if (qrMode === "none") {
    console.log("\nQR output disabled. Paste this pairing code into the iPhone app:\n");
  } else {
    console.log("\nScan this QR with the iPhone:\n");
    qrcode.generate(payload, { small: true });
  }
  if (shouldPrintPairingCode) {
    console.log(`Pairing Code: ${payload}`);
  }
  if (process.env.REMODEX_PRINT_PAIRING_JSON === "true") {
    console.log(`Pairing Payload: ${redactedPairingPayload(pairingPayload)}`);
  }
  console.log(`\nSession ID: ${pairingPayload.sessionId}`);
  console.log(`Relay: ${pairingPayload.relay}`);
  console.log(`Device ID: ${pairingPayload.macDeviceId}`);
  console.log(`Expires: ${new Date(pairingPayload.expiresAt).toISOString()}\n`);
}

module.exports = { printQR };

function readQrMode() {
  return process.env.REMODEX_QR_MODE === "none" ? "none" : "small";
}

function redactedPairingPayload(pairingPayload) {
  return JSON.stringify({
    ...pairingPayload,
    relayAuthKey: pairingPayload.relayAuthKey ? "***REDACTED***" : pairingPayload.relayAuthKey,
  });
}
