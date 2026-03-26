/**
 * ARCADE MCP Server — TypeScript stub
 *
 * NOTE: This is a scaffold. The FastMCP Python implementation (server.py +
 * arcade_tools.py) is the reference implementation. The tools below have
 * TODO markers showing where to port the logic from arcade_tools.py.
 *
 * To use the TypeScript path:
 *   npm install && npm run build && npm start
 *
 * Tool list (matches Python implementation):
 *   arcade_init_project, arcade_start_project, arcade_get_status,
 *   arcade_list_projects, arcade_add_task, arcade_get_cost, arcade_get_balance
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import * as fs from "fs";
import * as path from "path";

// Load mcp-server.conf
function loadConf(): void {
  const confPath = path.join(__dirname, "mcp-server.conf");
  if (fs.existsSync(confPath)) {
    const lines = fs.readFileSync(confPath, "utf8").split("\n");
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed && !trimmed.startsWith("#") && trimmed.includes("=")) {
        const [k, ...rest] = trimmed.split("=");
        const v = rest.join("=").replace(/^["']|["']$/g, "");
        if (!process.env[k.trim()]) {
          process.env[k.trim()] = v;
        }
      }
    }
  }
}

loadConf();

const server = new Server(
  { name: "arcade", version: "0.2.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "arcade_init_project",
      description: "Initialize a new ARCADE project with scaffold files",
      inputSchema: {
        type: "object",
        properties: {
          project: { type: "string", description: "Project name" },
          mode: { type: "string", description: "Default mode: reasoning | scaffold | oauth", default: "reasoning" },
        },
        required: ["project"],
      },
    },
    {
      name: "arcade_start_project",
      description: "Launch an ARCADE loop session in tmux",
      inputSchema: {
        type: "object",
        properties: {
          project: { type: "string" },
          mode: { type: "string", default: "reasoning" },
        },
        required: ["project"],
      },
    },
    {
      name: "arcade_get_status",
      description: "Get current project status: queue counts, next chunk, open issues",
      inputSchema: {
        type: "object",
        properties: { project: { type: "string" } },
        required: ["project"],
      },
    },
    {
      name: "arcade_list_projects",
      description: "List all ARCADE projects",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "arcade_add_task",
      description: "Append a task chunk to a project queue",
      inputSchema: {
        type: "object",
        properties: {
          project: { type: "string" },
          task: { type: "string", description: "Task text, e.g. '[REASONING] Design the API'" },
        },
        required: ["project", "task"],
      },
    },
    {
      name: "arcade_get_cost",
      description: "Get cost data from run-log.md",
      inputSchema: {
        type: "object",
        properties: {
          project: { type: "string" },
          scope: { type: "string", default: "last_run", description: "last_run | session | all_time" },
        },
        required: ["project"],
      },
    },
    {
      name: "arcade_get_balance",
      description: "Get inference provider balance or usage",
      inputSchema: { type: "object", properties: {} },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  // TODO: Port implementations from arcade_tools.py
  // Each tool below returns a stub response. Replace with actual logic.

  switch (name) {
    case "arcade_init_project":
      // TODO: port _arcade_init_project() from arcade_tools.py
      return { content: [{ type: "text", text: JSON.stringify({ status: "stub", message: "TODO: implement — see arcade_tools.py" }) }] };

    case "arcade_start_project":
      // TODO: port _arcade_start_project() from arcade_tools.py
      return { content: [{ type: "text", text: JSON.stringify({ status: "stub", message: "TODO: implement — see arcade_tools.py" }) }] };

    case "arcade_get_status":
      // TODO: port _arcade_get_status() from arcade_tools.py
      return { content: [{ type: "text", text: JSON.stringify({ status: "stub", message: "TODO: implement — see arcade_tools.py" }) }] };

    case "arcade_list_projects":
      // TODO: port _arcade_list_projects() from arcade_tools.py
      return { content: [{ type: "text", text: JSON.stringify({ status: "stub", message: "TODO: implement — see arcade_tools.py" }) }] };

    case "arcade_add_task":
      // TODO: port _arcade_add_task() from arcade_tools.py
      return { content: [{ type: "text", text: JSON.stringify({ status: "stub", message: "TODO: implement — see arcade_tools.py" }) }] };

    case "arcade_get_cost":
      // TODO: port _arcade_get_cost() from arcade_tools.py
      return { content: [{ type: "text", text: JSON.stringify({ status: "stub", message: "TODO: implement — see arcade_tools.py" }) }] };

    case "arcade_get_balance":
      // TODO: port _arcade_get_balance() from arcade_tools.py
      return { content: [{ type: "text", text: JSON.stringify({ status: "stub", message: "TODO: implement — see arcade_tools.py" }) }] };

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("ARCADE MCP Server running (TypeScript stub)");
}

main().catch(console.error);
