// FILE: relay.js
// Purpose: Re-export the shared Remodex relay core for self-hosted relay entrypoints.
// Layer: Standalone server module
// Exports: setupRelay, getRelayStats

module.exports = require("../phodex-bridge/src/relay-core");
