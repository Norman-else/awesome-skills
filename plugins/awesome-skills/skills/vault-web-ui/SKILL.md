---
name: vault-web-ui
description: Open the Vault Web UI in a browser through the Vault MCP integration. Use when Codex needs to launch Vault's web interface for interactive inspection, or when the user says things like `open vault web ui`, `open vault ui`, or `launch vault in browser`.
---

# Vault Web UI

## Overview

Use this skill to open the Vault Web UI in the user's browser through the Vault MCP integration. Keep the flow minimal and return the opened URL when the tool provides one.

## Workflow

1. Confirm the user wants to open the Vault Web UI, not read, edit, or share a secret.
2. Call `mcp__mcp_vault__vault_web_ui_open`.
3. If the tool succeeds, reply briefly that the Vault Web UI was opened and include the returned URL as a clickable link when available.
4. If the tool fails, explain the blocker briefly and stop.

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
