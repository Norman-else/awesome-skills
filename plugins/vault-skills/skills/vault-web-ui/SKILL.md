---
name: vault-web-ui
description: Open the Vault Web UI in a browser through the Vault MCP integration. Use when Codex needs to launch Vault's web interface for interactive inspection, or when the user says things like `open vault web ui`, `open vault ui`, or `launch vault in browser`.
---

# Vault Web UI

## Overview

Use this skill to open the Vault Web UI in the user's browser through the Vault MCP integration. Keep the flow minimal and return the opened URL when the tool provides one.

## Invoking with no input IS the request

This skill has exactly one action: open the Vault Web UI. When it is invoked with no extra prompt or arguments, treat the invocation itself as that request — call the tool immediately. Do NOT ask the user for a prompt or for confirmation first; a prompt is optional and its absence is not a reason to stop and ask.

## Workflow

1. Call the connected Vault MCP tool `vault_web_ui_open` straight away (no confirmation prompt). Some clients expose it as `mcp__mcp_vault__vault_web_ui_open`; discover the connected tool if its prefix differs. The only reason to pause is if the user's wording clearly asks to read, edit, or share a secret instead — then redirect to the right skill.
2. If the tool fails, explain the blocker briefly and stop.
3. A successful tool result only confirms that the browser was launched, NOT that the UI loaded. Verify the returned URL before claiming success. Only fetch the public HTML and its referenced same-origin JS/CSS assets; do not call secret APIs or inspect an authenticated page's contents. Use a bounded HTTP request (for example, a 5-second timeout), without following redirects to a different origin. Verify only a loopback URL returned by the tool; never guess a port or probe an external host. Retry briefly if the server is still starting.
4. Treat `Error loading UI template` as a failure even with HTTP 200. For the React UI, check that HTML contains the root mount element and that the referenced `/static/ui/` JS/CSS resources return successfully with appropriate content types, not an HTML error page. If verification is unavailable, say that the browser was opened but the page could not be verified.
5. If verification fails, follow the recovery guidance below. Otherwise reply briefly with the verified URL.

## React UI and recovery

The refactored Vault UI is a React/Vite application served by the same Flask server as the API. The backend loads `src/vault_mcp/static/ui/index.html`, with assets under `/static/ui/`. The previous `src/vault_mcp/templates/vault_ui.html` is obsolete. Do not recreate it, start a separate Vite server, or substitute port 5173/8765 for the URL returned by MCP.

Resolve the actual Vault MCP source/install location from the current project or confirmed runtime metadata, not from the skill directory or an assumed personal path. Inspect only relevant source/build files and template-error log lines; never dump MCP environment configuration, credentials, or complete logs. If the runtime location cannot be established, report the blocker instead of modifying an unrelated checkout.

- **Stale MCP process after an update:** If the current source loads `static/ui/index.html` and built assets exist, but the running server's template error still names `templates/vault_ui.html`, the MCP process has old Python code in memory. Rebuilding the frontend or repeatedly calling the open tool will not reload it. Ask the user to restart/reconnect the Vault MCP integration in their client, then invoke this skill again. Do not kill processes, start a second MCP server, log out, or reset authentication automatically. A restart can discard the in-memory login. Use the newly returned URL after restart because the port may change.
- **Missing React build:** Confirm the current backend expects `static/ui/index.html`, then inspect `frontend/package.json` and `frontend/vite.config.ts` in that same installation. If the build output or referenced assets are missing and local repair is authorized, use its lockfile (`npm --prefix <vault-mcp-root>/frontend ci`) and run `npm --prefix <vault-mcp-root>/frontend run build`. This project's build includes TypeScript checking and writes to `src/vault_mcp/static/ui/`. Retain those runtime assets. Do not install or build on every invocation, overwrite source edits, or build a different checkout from the running service. If dependencies/build fail, report the error and stop.
- **Installed package missing assets:** If the active installation has no frontend source, request an updated package containing the built UI rather than inventing a template or building into another Python installation.
- **Other failure:** Report the failed page/asset check concisely. Do not mask it with a success confirmation or attempt unrelated secret-management operations.

After an authorized repair or a user-confirmed MCP restart, call the open tool again and repeat verification once. If it still fails, stop with the remaining blocker.

## Response Rules

- Prefer a short confirmation such as `Vault Web UI is open: [http://localhost:43616](http://localhost:43616)`.
- Do not read or expose secret values.
- Do not substitute secret-management actions such as `mcp__mcp_vault__vault_read`, `mcp__mcp_vault__vault_kv_get`, or `mcp__mcp_vault__vault_share_secret` unless the user separately asks for them.
- Do not add authentication steps. Opening the UI is enough because the page itself handles login when needed.

## Examples

- User request: `open vault web ui`
  Action: call `mcp__mcp_vault__vault_web_ui_open`.
- User request: `open vault ui`
  Action: call `mcp__mcp_vault__vault_web_ui_open`.
