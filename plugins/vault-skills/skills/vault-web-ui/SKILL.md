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

1. Call `mcp__mcp_vault__vault_web_ui_open` straight away (no confirmation prompt). The only reason to pause is if the user's wording clearly asks to read, edit, or share a secret instead — then redirect to the right skill.
2. If the tool succeeds, reply briefly that the Vault Web UI was opened and include the returned URL as a clickable link when available.
3. If the tool fails, explain the blocker briefly and stop.

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
