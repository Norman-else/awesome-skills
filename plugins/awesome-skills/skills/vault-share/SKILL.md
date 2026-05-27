---
name: vault-share
description: Securely send a Vault secret or dynamic database credential to a Slack user by private DM without exposing the secret content in chat. Use when Codex needs to share credentials from Vault with a teammate in Slack, especially for requests like "share secret X with Y", "DM the db creds to Alice", "把 dev db 发给 Norman", "处理最新 DB 凭据申请", or terse slash-style input such as "vault-share ENV TYPE TARGET USER" and "vault-share PATH USER".
---

# Vault Share

## Overview

Use this skill to route a Vault secret directly to a Slack DM while keeping the secret out of the conversation. User-supplied requests are authoritative: when the current user prompt explicitly identifies the Vault target and Slack recipient, parse and execute that request directly without checking `database-credentials-ops`. Only check `database-credentials-ops` for the newest DB credential workflow request when the user asks to process the latest DB credential request, asks to check Slack, or does not provide enough request details to resolve the target and recipient. Use `mcp__mcp_vault__vault_login` first whenever the resolved request names an environment, or when the share tool reports that authentication is missing. Then use `mcp__mcp_vault__vault_share_secret` to send the secret. The response should confirm delivery status without printing secret material.

## Workflow

1. Parse the current user prompt first.
2. If the prompt explicitly resolves the Vault target and Slack recipient with high confidence, skip Slack DB request preflight and use the user-provided request as the resolved input.
3. Run the Slack DB request preflight in `database-credentials-ops` only when the user asks to process the latest DB credential request, asks to check Slack, or leaves the Vault target or Slack recipient unresolved.
4. Extract the Vault target and Slack recipient from the newest valid Slack workflow request only when preflight is required, then overlay any explicit user-supplied fields as intentional overrides.
5. Accept natural language, slash-style input, or terse positional input such as `dev db item-management-service Norman` when the user prompt or required Slack preflight does not provide every required field.
6. If either the Vault path or Slack user is missing after combining available fields, ask only for the missing field.
7. Normalize environment, secret type, mount, and path.
8. If the resolved request names `dev`, `sat`, `prod`, or `local`, call `mcp__mcp_vault__vault_login` for that environment before sharing.
9. Call `mcp__mcp_vault__vault_share_secret`.
10. If the share fails with an authentication error and an environment is known, call `mcp__mcp_vault__vault_login` for that environment and retry the share once.
11. Report only whether the share succeeded and which Slack user received it.

## Slack DB Request Preflight

- Do not call `mcp__mcp_vault__vault_get_latest_db_credential_request` when the current user prompt already provides an explicit, high-confidence Vault target and Slack recipient.
- Before any call to `mcp__mcp_vault__vault_login` or `mcp__mcp_vault__vault_share_secret` for a Slack-derived request, call `mcp__mcp_vault__vault_get_latest_db_credential_request` with `include_processed_status: true`.
- Never use Slack connector tools such as `slack_read_channel`, `slack_search_public_and_private`, `slack_search_public`, `slack_read_thread`, or channel search tools for this workflow. The dedicated Vault MCP tool is the privacy boundary: it reads Slack server-side and returns only structured fields, never raw Slack messages or credential values.
- If `mcp__mcp_vault__vault_get_latest_db_credential_request` is unavailable, fails, or returns a permission error such as `missing_scope`, stop immediately and report that the dedicated Vault MCP preflight needs to be fixed. Do not fall back to Slack connector tools.
- Treat the returned `request` object as the only source of Slack-derived fields. Use `database`, `environment`, `recipient`, `path`, and `status`; do not ask Slack directly for surrounding channel messages.
- Treat a message as a DB credential workflow request only when it is directed at the current user and contains the request pattern `Please provide the DB credential to`, a `Database:` field, and an `Environment:` field.
- Parse `Database:` as the database service name, parse `Environment:` as the Vault environment, and parse the Slack mention after `Please provide the DB credential to` as the recipient who should receive the credential.
- Ignore the mention of the current user at the beginning of the workflow message; that user is the approver/operator, not the credential recipient.
- For DB workflow requests, set `secret_type: db` and map the database service to `path: database/creds/SERVICE`.
- Preserve the source Slack message timestamp or link internally for confidence checks, but do not include it in the Vault share payload unless a tool explicitly needs it.
- Before calling any Vault tool, use the `status` returned by `mcp__mcp_vault__vault_get_latest_db_credential_request`. If the latest request was fetched without status, call `mcp__mcp_vault__vault_get_db_credential_request_status` with the request's `channel_id`, `request_ts`, `environment`, and `recipient.id`.
- Treat a request as already handled when the dedicated status tool returns `already_processed: true` with `confidence: high`. The status tool may inspect notification messages containing credential material, but it must not return those values to the AI.
- If the newest matching request has already been handled, stop immediately and report that the latest request in `database-credentials-ops` was already processed. Do not call `mcp__mcp_vault__vault_login` or `mcp__mcp_vault__vault_share_secret`.
- Do not automatically skip past an already handled newest request to process an older request unless the user explicitly asks for the next unprocessed request.
- If no matching request is found, continue using the user's explicit request. If the user asked to process the latest request and none is found, stop and say no matching DB credential request was found in `database-credentials-ops`.
- If the newest matching request is ambiguous, missing a database, missing an environment, missing the recipient mention, or names an unsupported environment, do not call Vault. Ask for the missing or conflicting field.
- If the request appears possibly handled but the notification match is not high confidence, ask for confirmation before sending anything.
- If the Slack preflight request conflicts with explicit fields in the user's current prompt, prefer the explicit prompt only when it is clearly an override; otherwise ask for confirmation before sending anything.

## Parsing Rules

- Parse by token meaning first, not only by position.
- Recognize environments from the fixed set `dev`, `sat`, `prod`, and `local`.
- Recognize secret types from the fixed set `db` and `kv`.
- Recognize Slack workflow fields from message text or structured blocks, especially `Database: SERVICE`, `Environment: ENV`, and `Please provide the DB credential to @USER`.
- Treat filler words such as `send`, `share`, `to`, `给`, `发给`, and `发` as optional noise.
- Treat the remaining unmatched token or token tail as the Slack user only when that interpretation is unambiguous.
- If two interpretations are plausible, do not send anything yet. Ask a short clarification question instead.

## Shorthand Forms

- Prefer the shortest accepted form when the request is already unambiguous.
- Accept `ENV db SERVICE USER` as shorthand for a dynamic database credential at `database/creds/SERVICE` after logging into `ENV`.
- Accept `ENV kv PATH USER` as shorthand for a KV secret in the default `secret` mount after logging into `ENV`.
- Accept `PATH USER` when the environment is already stated elsewhere in the request or does not need to change.
- Accept out-of-order tokens only when the parse is still unambiguous after applying the parsing rules.

## Parameter Mapping

- If the Slack preflight parses a valid DB workflow request, call `mcp__mcp_vault__vault_share_secret` with `secret_type: db`, `path: database/creds/SERVICE`, and `slack_user: RECIPIENT`, after logging into the parsed environment.
- If the user explicitly names an environment such as `dev`, `sat`, `prod`, or `local`, call `mcp__mcp_vault__vault_login` for that environment first.
- If the user uses the shorthand `ENV db SERVICE USER`, call `mcp__mcp_vault__vault_share_secret` with `secret_type: db`, `path: database/creds/SERVICE`, and `slack_user: USER`.
- If the user uses the shorthand `ENV kv PATH USER`, call `mcp__mcp_vault__vault_share_secret` with `secret_type: kv`, `mount_point: secret`, `path: PATH`, and `slack_user: USER`.
- If the user provides a path starting with `database/creds/`, call the tool with `secret_type: db` and pass the full path unchanged.
- If the user provides a path starting with `secret/`, call the tool with `secret_type: kv`, `mount_point: secret`, and strip the leading `secret/` from the `path` field.
- If the user explicitly states a non-`secret` KV mount, use that mount as `mount_point` and pass the remaining subpath as `path`.
- Otherwise default to `secret_type: kv`, `mount_point: secret`, and pass the provided path unchanged.
- Pass `slack_user` exactly as the user supplied it unless they explicitly ask for a different Slack identity.

## Response Rules

- Never read back, quote, summarize, or infer secret values.
- Never print usernames, passwords, tokens, certificates, or raw JSON from Vault.
- Never print credential material found in Slack notification messages. Use those messages only as processed-state signals.
- Do not expose the full Slack request body if it contains incidental sensitive context. It is okay to mention the resolved environment, service name, and recipient in the final confirmation.
- Keep the user-facing confirmation brief. Example: `Shared the Vault secret with hansen in Slack.`
- If `mcp__mcp_vault__vault_share_secret` returns an authentication error and the environment is known, call `mcp__mcp_vault__vault_login`, then retry once before replying.
- Before sending, internally verify that environment, secret type, target path, and Slack user are all resolved with high confidence.
- If parsing confidence is not high, ask for confirmation with the interpreted form instead of sending immediately.
- If the tool fails because Vault access or environment selection is missing, explain the blocker briefly and ask only for the minimum detail needed to continue.

## Examples

- User request: `处理最新 DB 凭据申请`
  Slack preflight finds a `database-credentials-ops` workflow message directed at the current user: `Please provide the DB credential to @Hansen Huang`, `Database: item-management-service`, `Environment: prod`.
  Action: call `mcp__mcp_vault__vault_login` with `environment: prod`, then call `mcp__mcp_vault__vault_share_secret` with `secret_type: db`, `path: database/creds/item-management-service`, `slack_user: Hansen Huang`.
- User request: `处理最新 DB 凭据申请`
  Slack preflight finds the newest matching request, then finds a later Vault notification that database credentials were sent to the same recipient for the same environment by the current user.
  Action: stop and report that the latest request was already processed. Do not call any Vault tool.
- User request: `dev db item-management-service Norman`
  Action: call `mcp__mcp_vault__vault_login` with `environment: dev`, then call `mcp__mcp_vault__vault_share_secret` with `secret_type: db`, `path: database/creds/item-management-service`, `slack_user: Norman`.
- User request: `Norman dev db item-management-service`
  Action: accept the out-of-order form only because the parse is still unambiguous, then call `mcp__mcp_vault__vault_login` with `environment: dev` and share `database/creds/item-management-service` with `Norman`.
- User request: `db Norman item-management-service`
  Action: do not guess. Ask whether `Norman` is the Slack user and whether the intended environment is `dev`, `sat`, `prod`, or `local`.
- User request: `把 warehouse-management-service 发给 hansen`
  Action: call `mcp__mcp_vault__vault_share_secret` with `secret_type: kv`, `mount_point: secret`, `path: warehouse-management-service`, `slack_user: hansen`.
- User request: `share database/creds/reporting-api to alice`
  Action: call `mcp__mcp_vault__vault_share_secret` with `secret_type: db`, `path: database/creds/reporting-api`, `slack_user: alice`.
- User request: `vault-share secret/myapp/config to bob`
  Action: call `mcp__mcp_vault__vault_share_secret` with `secret_type: kv`, `mount_point: secret`, `path: myapp/config`, `slack_user: bob`.
