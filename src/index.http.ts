#!/usr/bin/env node

import { createServer, type IncomingMessage } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { XeroMcpServer } from "./server/xero-mcp-server.js";
import { ToolFactory } from "./tools/tool-factory.js";

const PORT = parseInt(process.env.PORT ?? "3000", 10);
const MCP_AUTH_TOKEN = process.env.MCP_AUTH_TOKEN;

if (!MCP_AUTH_TOKEN) {
  console.warn(
    "WARNING: MCP_AUTH_TOKEN is not set — /mcp is unauthenticated. " +
      "This server holds the Xero client credential itself, so an unauthenticated " +
      "/mcp accepts calls from anyone who can reach it. Fine for local/dev; " +
      "REQUIRED before deploying behind external ingress (see infra/main.bicep).",
  );
}

/**
 * Constant-time bearer-token check against MCP_AUTH_TOKEN. When unset, every
 * request is authorized (dev-mode fallback — see the startup warning above).
 */
function isAuthorized(req: IncomingMessage): boolean {
  if (!MCP_AUTH_TOKEN) return true;

  const header = req.headers.authorization ?? "";
  const expected = `Bearer ${MCP_AUTH_TOKEN}`;

  const a = Buffer.from(header);
  const b = Buffer.from(expected);
  // timingSafeEqual throws on length mismatch rather than returning false —
  // guard explicitly rather than let a length probe short-circuit the compare.
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

const mcpServer = XeroMcpServer.GetServer();
ToolFactory(mcpServer);

// Stateless transport: no in-process session state; safe for scale-to-zero and
// single-instance Container Apps where each tool call re-authenticates via env-var creds.
const transport = new StreamableHTTPServerTransport({
  sessionIdGenerator: undefined,
});

await mcpServer.connect(transport);

const httpServer = createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", transport: "streamable-http" }));
    return;
  }

  if (req.url === "/mcp") {
    if (!isAuthorized(req)) {
      res.writeHead(401, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }
    await transport.handleRequest(req, res);
    return;
  }

  res.writeHead(404);
  res.end();
});

const shutdown = () => {
  httpServer.close(() => process.exit(0));
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

httpServer.listen(PORT, "0.0.0.0", () => {
  console.log(`Xero MCP Server listening on :${PORT} (Streamable HTTP)`);
});
