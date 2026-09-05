#!/usr/bin/env node

import { createServer } from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { XeroMcpServer } from "./server/xero-mcp-server.js";
import { ToolFactory } from "./tools/tool-factory.js";

const PORT = parseInt(process.env.PORT ?? "3000", 10);

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
