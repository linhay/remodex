const CLEANUP_DELAY_MS = 60_000;
const CLOSE_CODE_INVALID_REQUEST = 4000;
const CLOSE_CODE_MAC_REPLACED = 4001;
const CLOSE_CODE_SESSION_UNAVAILABLE = 4002;
const CLOSE_CODE_IPHONE_REPLACED = 4003;
const CLOSE_CODE_FORBIDDEN = 4004;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === "/health") {
      return Response.json({
        ok: true,
        service: "remodex-relay",
        websocketPath: "/relay/:sessionId",
        relayAuthEnabled: Boolean(env.REMODEX_RELAY_KEY),
      });
    }

    const match = url.pathname.match(/^\/relay\/([^/]+)$/);
    if (!match) {
      return new Response("Not Found", { status: 404 });
    }

    const sessionId = match[1];
    const durableId = env.RELAY_SESSION.idFromName(sessionId);
    const stub = env.RELAY_SESSION.get(durableId);
    return stub.fetch(request);
  },
};

export class RelaySession {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected websocket upgrade", { status: 426 });
    }

    const url = new URL(request.url);
    const match = url.pathname.match(/^\/relay\/([^/]+)$/);
    const sessionId = match?.[1];
    const role = request.headers.get("x-role");
    const relayAuthKey = request.headers.get("x-remodex-relay-key")?.trim() || "";

    if (!sessionId || (role !== "mac" && role !== "iphone")) {
      return this.closeDuringUpgrade(
        CLOSE_CODE_INVALID_REQUEST,
        "Missing sessionId or invalid x-role header"
      );
    }

    if ((this.env.REMODEX_RELAY_KEY || "").trim() && relayAuthKey !== this.env.REMODEX_RELAY_KEY.trim()) {
      return this.closeDuringUpgrade(
        CLOSE_CODE_FORBIDDEN,
        "Missing or invalid relay key"
      );
    }

    const pair = new WebSocketPair();
    const [clientSocket, serverSocket] = Object.values(pair);

    if (role === "iphone" && !this.getOpenMac()) {
      serverSocket.accept();
      serverSocket.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return new Response(null, { status: 101, webSocket: clientSocket });
    }

    if (role === "mac") {
      const existingMac = this.getOpenMac();
      if (existingMac) {
        existingMac.close(CLOSE_CODE_MAC_REPLACED, "Replaced by new Mac connection");
      }
    } else {
      for (const existingClient of this.getOpenIphones()) {
        existingClient.close(
          CLOSE_CODE_IPHONE_REPLACED,
          "Replaced by newer iPhone connection"
        );
      }
    }

    serverSocket.serializeAttachment({ role, sessionId });
    this.ctx.acceptWebSocket(serverSocket, [role]);
    this.clearCleanupAlarm();

    if (role === "mac") {
      console.log(`[relay] Mac connected -> session ${sessionId}`);
    } else {
      const clientCount = this.getOpenIphones().length;
      console.log(`[relay] iPhone connected -> session ${sessionId} (${clientCount} client(s))`);
    }

    return new Response(null, { status: 101, webSocket: clientSocket });
  }

  webSocketMessage(ws, message) {
    const role = this.getSocketRole(ws);
    const sessionId = this.getSessionId(ws);
    const size = this.byteLength(message);

    console.log(`[relay] forwarded ${role} -> session ${sessionId} (${size} bytes)`);

    if (role === "mac") {
      for (const client of this.getOpenIphones()) {
        client.send(message);
      }
      return;
    }

    const mac = this.getOpenMac();
    if (mac) {
      mac.send(message);
    }
  }

  webSocketClose(ws) {
    const role = this.getSocketRole(ws);
    const sessionId = this.getSessionId(ws);

    if (role === "mac") {
      console.log(`[relay] Mac disconnected -> session ${sessionId}`);
      for (const client of this.getOpenIphones()) {
        client.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac disconnected");
      }
    } else {
      console.log(
        `[relay] iPhone disconnected -> session ${sessionId} (${this.getOpenIphones().length} remaining)`
      );
    }

    this.scheduleCleanupIfIdle();
  }

  webSocketError(ws, error) {
    const role = this.getSocketRole(ws);
    const sessionId = this.getSessionId(ws);
    console.error(`[relay] WebSocket error (${role}, session ${sessionId}): ${error?.message || error}`);
  }

  async alarm() {
    if (this.getOpenSockets().length === 0) {
      await this.ctx.storage.deleteAll();
      console.log("[relay] Session cleaned up");
    }
  }

  getOpenSockets(tag) {
    return this.ctx
      .getWebSockets(tag)
      .filter((socket) => socket.readyState === WebSocket.OPEN);
  }

  getOpenMac() {
    return this.getOpenSockets("mac")[0] || null;
  }

  getOpenIphones() {
    return this.getOpenSockets("iphone");
  }

  getSocketRole(ws) {
    return ws.deserializeAttachment()?.role || "unknown";
  }

  getSessionId(ws) {
    return ws.deserializeAttachment()?.sessionId || "unknown";
  }

  byteLength(message) {
    if (typeof message === "string") {
      return new TextEncoder().encode(message).byteLength;
    }
    if (message instanceof ArrayBuffer) {
      return message.byteLength;
    }
    return message?.byteLength ?? 0;
  }

  scheduleCleanupIfIdle() {
    if (this.getOpenSockets().length > 0) {
      return;
    }
    this.ctx.storage.setAlarm(Date.now() + CLEANUP_DELAY_MS);
  }

  clearCleanupAlarm() {
    this.ctx.storage.deleteAlarm().catch(() => {});
  }

  closeDuringUpgrade(code, reason) {
    const pair = new WebSocketPair();
    const [clientSocket, serverSocket] = Object.values(pair);
    serverSocket.accept();
    serverSocket.close(code, reason);
    return new Response(null, { status: 101, webSocket: clientSocket });
  }
}
