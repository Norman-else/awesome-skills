---
name: vault-sync-db
description: Sync a service's dynamic Vault database credentials into the local PostgreSQL MCP config (~/postgresql-mcp-config/environments.json) so the PostgreSQL MCP can connect, without exposing the credentials in chat. Use when the user wants fresh DB credentials wired into their Postgres MCP, especially for requests like "sync dev accounting db", "sync the item-management-service db creds to postgres mcp", "refresh my prod data db credentials", "my postgres mcp password expired for sat accounting", "把 dev 的 accounting-service 数据库凭证同步到 postgresql mcp", or terse slash-style input such as "vault-sync-db ENV SERVICE [SERVICE...]". Do NOT use for sending credentials to another person (use vault-share).
---

# Vault Sync DB

## Overview

Use this skill to refresh the database credentials the PostgreSQL MCP uses. The Vault MCP tool `vault_sync_db_creds_to_postgres_mcp` generates the dynamic credentials server-side and writes them straight into `~/postgresql-mcp-config/environments.json` — the same logic as the Sync button in the Vault Web UI. The username and password never enter the conversation; the tool only returns the MCP environment name and whether it was `created` or `updated`.

Some clients expose the tools as `mcp__mcp_vault__*` or `mcp__vault__*`; discover the connected prefix if it differs.

## Workflow

1. Parse the environment (`dev`, `sat`, `prod`, `local`) and one or more services from the user prompt.
2. If the environment or the service is missing, ask only for the missing field. Do not guess an environment.
3. Call `vault_login` with the environment.
4. For each service, call `vault_sync_db_creds_to_postgres_mcp` with `service: SERVICE`. One call per service; reuse the single login for services in the same environment. Different environments need their own `vault_login` first, because the target MCP environment name is derived from the currently logged-in environment.
5. If a sync fails with an authentication error, call `vault_login` for that environment and retry that sync once.
6. Report the result per service using the returned `environment` and `action`.

## Parsing Rules

- Parse by token meaning, not position: `dev accounting`, `accounting dev`, and `sync the accounting db on dev` are the same request.
- Treat filler words such as `sync`, `refresh`, `db`, `database`, `creds`, `to postgres mcp` as noise.
- Services are Vault database roles, normally `NAME-service` (for example `accounting-service`, `item-management-service`). If the user gives a bare name such as `accounting`, pass `accounting-service`. If the tool then reports the path was not found, call `vault_list` on `database/roles` to find the matching role and retry once, or ask when several roles are plausible.
- A full path such as `database/creds/accounting-service` is accepted by the tool unchanged.
- The resulting MCP environment is `ENV-NAME` with the `-service` suffix removed, for example `dev-accounting` or `prod-item-management`.

## Response Rules

- Never call `vault_read` on `database/creds/...` for this workflow, and never open or print `environments.json`: both would expose the credentials. The sync tool is the privacy boundary.
- Never edit `environments.json` yourself. If the tool reports the config file is missing or contains invalid JSON, relay the error and stop; the user must fix the PostgreSQL MCP config.
- If creating a new environment fails because `host.db_server` is missing from `secret/application`, relay that blocker and stop.
- Keep the confirmation brief and free of secret material. Example: `Synced dev-accounting (updated). Credentials expire in 1h.` Mention the expiry only when the tool returns `lease_duration`.
- When `action` is `created`, mention that a new PostgreSQL MCP environment was added and name it, so the user knows what to switch to.
- Do not switch the PostgreSQL MCP environment or run queries unless the user separately asks.

## Examples

- User request: `sync dev accounting db`
  Action: call `vault_login` with `environment: dev`, then `vault_sync_db_creds_to_postgres_mcp` with `service: accounting-service`. Reply `Synced dev-accounting (updated).`
- User request: `vault-sync-db sat accounting-service backend-payment-gateway-service`
  Action: log into `sat` once, then sync each service with its own tool call. Report both results.
- User request: `refresh my data db creds`
  Action: the environment is missing. Ask whether it is `dev`, `sat`, `prod`, or `local`; do not sync anything yet.
- User request: `把 prod 的 item-management-service 同步到 postgres mcp`
  Action: call `vault_login` with `environment: prod`, then sync `item-management-service`. If the tool returns `action: created`, reply that the new environment `prod-item-management` was added.
