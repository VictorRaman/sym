# LemonMCP

> **Status:** `incubator`
> **Default runtime:** no
> **Keep reason:** exploratory MCP bridge; retained for external-tool integration work, but not part of the default Lemon runtime

## Quick Orientation

`lemon_mcp` is a bridge app around Model Context Protocol concepts. It depends on
`coding_agent` and `agent_core`, but its OTP application is currently minimal and
it is not started by `bin/lemon`.

Treat it as an incubating side integration, not as a platform-core subsystem.

## Key Files

| File | Purpose |
|---|---|
| `lib/lemon_mcp.ex` | Top-level namespace and protocol version |
| `lib/lemon_mcp/application.ex` | Currently minimal OTP app; no default children |
| `lib/lemon_mcp/client.ex` | MCP client lifecycle |
| `lib/lemon_mcp/server.ex` | MCP server process |
| `lib/lemon_mcp/server/handler.ex` | Request handling |
| `lib/lemon_mcp/tool_adapter.ex` | CodingAgent tool exposure layer |
| `lib/lemon_mcp/transport/*.ex` | stdio / HTTP transport implementations |

## Maintenance Rules

- Do not describe this app as a default Lemon runtime dependency in docs.
- Keep compile-time boundaries narrow: it is a bridge, not a new platform core.
- If the app gains real runtime ownership, promote it explicitly in `docs/platform_tiers.md`.
