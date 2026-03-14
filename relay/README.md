# Relay

This folder contains the thin WebSocket relay used by the default hosted Remodex pairing flow.

Two deployment targets are included:

- `relay.js`: the original Node.js `ws` module
- `server.cjs`: a local HTTP/WebSocket server for self-hosting or Cloudflare Tunnel
- `worker.js`: a Cloudflare Workers + Durable Objects deployment target

In production, the default hosted relay runs on my VPS. If you want, you can inspect this code, fork it, and host the same relay yourself.

## What It Does

- accepts WebSocket connections at `/relay/{sessionId}`
- pairs one Mac host with one live iPhone client for a session
- forwards secure control messages and encrypted payloads between Mac and iPhone
- logs only connection metadata and payload sizes, not plaintext prompts or responses
- exposes lightweight stats for a health endpoint

## What It Does Not Do

- it does not run Codex
- it does not execute git commands
- it does not contain your repository checkout
- it does not persist the local workspace on the server

Codex, git, and local file operations still run on the user's Mac.
The relay is intentionally blind to Remodex application contents once the secure handshake completes.

## Security Model

Remodex uses the relay as a transport hop, not as a trusted application server.

- The pairing QR gives the iPhone the bridge identity public key plus short-lived session details.
- The iPhone and bridge perform a signed handshake, derive shared AES-256-GCM keys with X25519 + HKDF-SHA256, and then encrypt application payloads end to end.
- The relay can still observe connection metadata and the plaintext secure control messages needed to establish the encrypted session.
- The relay does not receive plaintext Remodex application payloads after the secure session is active.

## Protocol Notes

- path: `/relay/{sessionId}`
- required header: `x-role: mac` or `x-role: iphone`
- optional header: `x-remodex-relay-key` when relay auth is enabled
- close code `4000`: invalid session or role
- close code `4001`: previous Mac connection replaced
- close code `4002`: session unavailable / Mac disconnected
- close code `4003`: previous iPhone connection replaced
- close code `4004`: missing or invalid relay key

## Cloudflare Deployment

The Cloudflare version keeps one Durable Object per `sessionId`, which preserves the same relay contract as the Node server:

- WebSocket path: `/relay/{sessionId}`
- Required header: `x-role: mac` or `x-role: iphone`
- Close codes: `4000`, `4001`, `4002`, `4003`, `4004`

Deploy it from this folder:

```sh
npm install
wrangler secret put REMODEX_RELAY_KEY
npm run deploy
```

After deploy, point the bridge to your Worker URL:

```sh
REMODEX_RELAY=wss://<your-worker-domain>/relay remodex up
```

The health check stays available at:

```txt
https://<your-worker-domain>/health
```

## Cloudflare Tunnel

If you already run `cloudflared tunnel`, the simplest path is to keep the relay local and expose it through your tunnel.

Start the local relay:

```sh
npm install
REMODEX_RELAY_KEY=your-shared-secret npm start
```

Then start the bridge with the same secret:

```sh
REMODEX_RELAY=wss://<your-tunnel-domain>/relay \
REMODEX_RELAY_KEY=your-shared-secret \
npm start
```

If you want to keep using the published package instead of the repo checkout:

```sh
REMODEX_RELAY=wss://<your-tunnel-domain>/relay \
REMODEX_RELAY_KEY=your-shared-secret \
remodex up
```

Without `REMODEX_RELAY_KEY`, the relay stays compatible with the old open behavior.

Start the local relay without auth:

```sh
npm install
npm start
```

That serves:

- `http://127.0.0.1:8787/health`
- `ws://127.0.0.1:8787/relay/{sessionId}`

Then point your tunnel hostname at `http://127.0.0.1:8787`. After that, use the public hostname in Remodex:

```sh
REMODEX_RELAY=wss://<your-tunnel-domain>/relay remodex up
```

## Usage

`relay.js` exports:

- `setupRelay(wss)`
- `getRelayStats()`

It is meant to be attached to a `ws` `WebSocketServer` from your own HTTP server.
