---
name: vault-share
description: Securely send a Vault secret or dynamic database credential to a Slack user by private DM without exposing the secret content in chat. Supports sharing only a subset of a KV secret's keys. Use when Codex needs to share credentials from Vault with a teammate in Slack, especially for requests like "share secret X with Y", "share only DB_HOST and DB_PORT of X with Y", "DM the db creds to Alice", "send dev db to Norman", "process the latest DB credential request", "process the pending DB credential requests" (handles multiple unprocessed requests for different services/recipients, not just the newest), or terse slash-style input such as "vault-share ENV TYPE TARGET USER" and "vault-share PATH USER".
---

# Vault Share

## Overview

Use this skill to route a Vault secret directly to a Slack DM while keeping the secret out of the conversation. User-supplied requests are authoritative: when the current user prompt explicitly identifies the Vault target and Slack recipient, parse and execute that request directly without checking `infra-vault-ops`. Only check `infra-vault-ops` when the user asks to process DB credential requests, asks to check Slack, or does not provide enough request details to resolve the target and recipient. Use `mcp__mcp_vault__vault_login` first whenever the resolved request names an environment, or when the share tool reports that authentication is missing. Then use `mcp__mcp_vault__vault_share_secret` to send the secret. For KV secrets the user may restrict the share to specific keys via the `keys` parameter; database credentials are always sent in full. For Slack-derived workflow requests, mark the source request with 👀 when processing begins and ✅ after the share succeeds. The response should confirm delivery status without printing secret material.

When the user asks to process Slack DB requests, there may be MORE THAN ONE unprocessed request for different services or recipients. Always enumerate the full set of unprocessed requests via `mcp__mcp_vault__vault_get_pending_db_credential_requests` instead of handling only the newest one. The dedicated tool returns a deduplicated list (collapsing repeated requests for the same environment + service + recipient) split into fresh `pending_requests` and older `stale_requests`. Process the fresh ones after confirming the batch with the operator; treat stale ones individually with explicit per-item confirmation.

When this skill is invoked with no extra user-provided target, recipient, or path, treat the invocation itself as a request to process ALL unprocessed DB credential workflow requests from `infra-vault-ops`. Do not ask the user to provide a one-line request first.

## Workflow

1. Parse the current user prompt first.
2. If the prompt explicitly resolves the Vault target and Slack recipient with high confidence, skip Slack DB request preflight and use the user-provided request as the resolved input.
3. If the invocation has no explicit target and recipient, immediately run the Slack DB request preflight in `infra-vault-ops`; do not ask for shorthand examples first.
4. Run the Slack DB request preflight in `infra-vault-ops` when the user asks to process DB credential requests, asks to check Slack, or leaves the Vault target or Slack recipient unresolved.
5. When preflight is required, enumerate ALL unprocessed requests, present them, process each fresh one, and overlay any explicit user-supplied fields as intentional overrides. Process the requests one at a time; never collapse multiple distinct services or recipients into a single share.
6. Accept natural language, slash-style input, or terse positional input such as `dev db item-management-service Norman` when the user prompt or required Slack preflight does not provide every required field.
7. If either the Vault path or Slack user is missing after combining available fields, ask only for the missing field.
8. Normalize environment, secret type, mount, and path.
9. For a Slack-derived request, call `mcp__mcp_vault__vault_mark_db_credential_request` with its `channel_id`, `request_ts`, and `status: processing` immediately before processing it. This adds 👀 to the source request.
10. If the resolved request names `dev`, `sat`, `prod`, or `local`, call `mcp__mcp_vault__vault_login` for that environment before sharing.
11. Call `mcp__mcp_vault__vault_share_secret`.
12. If the share fails with an authentication error and an environment is known, call `mcp__mcp_vault__vault_login` for that environment and retry the share once.
13. After a Slack-derived request is shared successfully, call `mcp__mcp_vault__vault_mark_db_credential_request` again with `status: completed`. This adds ✅ while retaining 👀 as the acknowledgement marker. Do not add ✅ when sharing fails.
14. Report only whether the share succeeded and which Slack user received it.

## Slack DB Request Preflight

- Empty skill invocation means Slack DB request preflight. Do not respond with input examples before calling `mcp__mcp_vault__vault_get_pending_db_credential_requests`.
- Do not call `mcp__mcp_vault__vault_get_pending_db_credential_requests` when the current user prompt already provides an explicit, high-confidence Vault target and Slack recipient for a single share.
- Before any call to `mcp__mcp_vault__vault_login` or `mcp__mcp_vault__vault_share_secret` for a Slack-derived request, call `mcp__mcp_vault__vault_get_pending_db_credential_requests` with `include_stale: true`.
- Never use Slack connector tools such as `slack_read_channel`, `slack_search_public_and_private`, `slack_search_public`, `slack_read_thread`, or channel search tools for this workflow. The dedicated Vault MCP tool is the privacy boundary: it reads Slack server-side and returns only structured fields, never raw Slack messages or credential values.
- If `mcp__mcp_vault__vault_get_pending_db_credential_requests` is unavailable, fails, or returns a permission error such as `missing_scope`, stop immediately and report that the dedicated Vault MCP preflight needs to be fixed. Do not fall back to Slack connector tools.
- Treat the returned `pending_requests` and `stale_requests` arrays as the only source of Slack-derived fields. For each request use `database`, `environment`, `recipient`, `path`, `status`, `age`, and `duplicate_count`; do not ask Slack directly for surrounding channel messages.
- The tool already deduplicates: requests sharing the same environment + service + recipient are collapsed to the newest one with `duplicate_count` showing how many were merged. Treat each returned entry as a single unit of work; do not re-send for the merged duplicates.
- For DB workflow requests, set `secret_type: db` and map the database service to `path: database/creds/SERVICE`.
- Preserve each request's `channel_id` and `request_ts` internally for status checks and reactions, but do not include them in the Vault share payload.
- Use only `mcp__mcp_vault__vault_mark_db_credential_request` for request reactions. Do not use generic Slack connector tools or reaction tools; the dedicated Vault MCP tool validates that the target is a DB credential request in the configured channel.
- Reaction failures are non-blocking: continue the credential share, report the marker failure briefly, and never claim 👀 or ✅ was added unless the marker tool succeeded.

### Handling multiple requests

- The tool returns the full list. Enumerate it; never silently process only the newest entry.
- When there are one or more fresh `pending_requests`, present a brief numbered summary (environment / service / recipient, and a duplicate note when `duplicate_count` > 1) and confirm the batch with the operator, then process the fresh requests one at a time: add 👀, log into the environment if needed, share the credential, and add ✅ only after success. Reuse a single login per environment across requests that share it.
- If the user explicitly asks to process only the latest/newest request, process just the first entry of `pending_requests` (the list is newest-first) and leave the rest.
- Process each request independently. Two requests for different services or recipients must each get their own `mcp__mcp_vault__vault_share_secret` call; never merge them.
- After processing the fresh batch, report a per-request result list (succeeded / skipped / failed) without printing any secret material.

### Stale and already-processed requests

- Requests in `stale_requests` are older than the fresh window (`age.tier` is `stale`). Never include them in the auto-processed batch. List them separately and process a stale request only after the operator explicitly confirms that specific one.
- The tool omits requests already handled with high confidence. A returned request whose `status.already_processed` is `true` (i.e. `possibly_processed`) means the match was only medium confidence — do not send it automatically; ask the operator to confirm before sharing.
- If `pending_requests` and `stale_requests` are both empty, report that no unprocessed DB credential request was found in `infra-vault-ops`. Do not call `mcp__mcp_vault__vault_login` or `mcp__mcp_vault__vault_share_secret`.

### Per-request validation

- Before any single share, if you need to re-check one request in isolation, call `mcp__mcp_vault__vault_get_db_credential_request_status` with that request's `channel_id`, `request_ts`, `environment`, `recipient.id`, and `database` (pass `database` so the check does not confuse a different service sent to the same recipient).
- If a request is ambiguous, missing a database, missing an environment, missing the recipient mention, or names an unsupported environment, do not call Vault for that one. Ask for the missing or conflicting field while still processing the others.
- If a request appears possibly handled but the notification match is not high confidence, ask for confirmation before sending that one.
- If the Slack preflight conflicts with explicit fields in the user's current prompt, prefer the explicit prompt only when it is clearly an override; otherwise ask for confirmation before sending anything.

## Parsing Rules

- Parse by token meaning first, not only by position.
- Recognize environments from the fixed set `dev`, `sat`, `prod`, and `local`.
- Recognize secret types from the fixed set `db` and `kv`.
- Recognize Slack workflow fields from message text or structured blocks, especially `Database: SERVICE`, `Environment: ENV`, and `Please provide the DB credential to @USER`.
- Treat filler words such as `send`, `share`, and `to` as optional noise.
- Recognize key-subset phrasing such as `only KEY1 and KEY2`, `just the KEY fields`, `only send KEY1/KEY2`, or an explicit key list after the path, and map it to the `keys` parameter. Key subsets apply to KV secrets only.
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
- If the user names specific keys of a KV secret (for example `only DB_HOST and DB_PORT`), pass them as the `keys` array so only those keys are sent. Never pass `keys` for `secret_type: db`; database credentials are always sent in full and have their own workflow.
- If the tool result includes `missing_keys`, relay the missing key names (names only, never values) so the user knows those keys were not sent. If the share fails because none of the requested keys exist, report the `available_keys` names and ask the user to pick from them.
- Pass `slack_user` exactly as the user supplied it unless they explicitly ask for a different Slack identity.

## Response Rules

- Never read back, quote, summarize, or infer secret values.
- Never print usernames, passwords, tokens, certificates, or raw JSON from Vault.
- Never print credential material found in Slack notification messages. Use those messages only as processed-state signals.
- Never add request reactions for a direct user-supplied share that did not come from Slack preflight; it has no validated source request to mark.
- Do not expose the full Slack request body if it contains incidental sensitive context. It is okay to mention the resolved environment, service name, and recipient in the final confirmation.
- Keep the user-facing confirmation brief. Example: `Shared the Vault secret with hansen in Slack.`
- If `mcp__mcp_vault__vault_share_secret` returns an authentication error and the environment is known, call `mcp__mcp_vault__vault_login`, then retry once before replying.
- Before sending, internally verify that environment, secret type, target path, and Slack user are all resolved with high confidence.
- If parsing confidence is not high, ask for confirmation with the interpreted form instead of sending immediately.
- If the tool fails because Vault access or environment selection is missing, explain the blocker briefly and ask only for the minimum detail needed to continue.

## Examples

- User request: `process the DB credential requests` (or empty `vault-share` invocation)
  Preflight calls `mcp__mcp_vault__vault_get_pending_db_credential_requests` and gets two fresh `pending_requests`: (1) `Database: item-management-service`, `Environment: prod`, recipient `@Hansen Huang`; (2) `Database: warehouse-management-service`, `Environment: dev`, recipient `@Norman`.
  Action: present both and confirm the batch. For each request, mark it `processing` (👀), log into the matching environment, share its credential, then mark it `completed` (✅) only after success. Report a per-request result list.
- User request: `process the DB credential requests`
  Preflight returns `pending_requests` for `service-b` (dev → Alice) but the `already_processed` high-confidence match for `service-a` (dev → Alice) was already filtered out by the tool.
  Action: process only `service-b`; do not resend `service-a`. The service-aware status check keeps the two distinct.
- User request: `process the DB credential requests`
  Preflight returns an empty `pending_requests` and two entries in `stale_requests` (each `age.tier: stale`).
  Action: do not auto-process. List the two stale requests and ask the operator to confirm each one individually before sharing.
- User request: `process the latest DB credential request`
  Preflight returns several `pending_requests`.
  Action: process only the first (newest) entry and leave the rest, since the user asked for the latest specifically.
- User request: `dev db item-management-service Norman`
  Action: call `mcp__mcp_vault__vault_login` with `environment: dev`, then call `mcp__mcp_vault__vault_share_secret` with `secret_type: db`, `path: database/creds/item-management-service`, `slack_user: Norman`.
- User request: `Norman dev db item-management-service`
  Action: accept the out-of-order form only because the parse is still unambiguous, then call `mcp__mcp_vault__vault_login` with `environment: dev` and share `database/creds/item-management-service` with `Norman`.
- User request: `db Norman item-management-service`
  Action: do not guess. Ask whether `Norman` is the Slack user and whether the intended environment is `dev`, `sat`, `prod`, or `local`.
- User request: `share warehouse-management-service with hansen`
  Action: call `mcp__mcp_vault__vault_share_secret` with `secret_type: kv`, `mount_point: secret`, `path: warehouse-management-service`, `slack_user: hansen`.
- User request: `share database/creds/reporting-api to alice`
  Action: call `mcp__mcp_vault__vault_share_secret` with `secret_type: db`, `path: database/creds/reporting-api`, `slack_user: alice`.
- User request: `vault-share secret/myapp/config to bob`
  Action: call `mcp__mcp_vault__vault_share_secret` with `secret_type: kv`, `mount_point: secret`, `path: myapp/config`, `slack_user: bob`.
- User request: `share only DB_HOST and DB_PORT of item-management-service with hansen`
  Action: call `mcp__mcp_vault__vault_share_secret` with `secret_type: kv`, `mount_point: secret`, `path: item-management-service`, `slack_user: hansen`, `keys: ["DB_HOST", "DB_PORT"]`.
- User request: `send just the API_TOKEN from secret/myapp/config to alice`
  Action: call `mcp__mcp_vault__vault_share_secret` with `secret_type: kv`, `mount_point: secret`, `path: myapp/config`, `slack_user: alice`, `keys: ["API_TOKEN"]`.
- User request: `share only the username of database/creds/reporting-api to alice`
  Action: do not pass `keys`; explain that database credentials are always shared in full, then confirm whether to send the complete credential.
