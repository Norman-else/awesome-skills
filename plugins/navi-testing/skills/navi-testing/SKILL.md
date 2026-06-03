---
name: navi-testing
description: Run post-deploy smoke tests against the deployed Navi Slack agent. Drives a dedicated Slack test channel (@mentions Navi), then VERIFIES each scenario on three layers — the Slack reaction lifecycle, Navi's actual thread reply, AND the execution Trace queried from the dev PostgreSQL — and reports failures with the scenario, what Navi actually did, and what was expected. Use when the user says "run navi tests", "smoke test navi", "test navi after deploy", "navi-testing", or wants to validate a Navi deployment.
---

# Navi Post-Deploy Smoke Test

## Overview

Navi's only functional entry point is a Slack message. This skill is the test
harness: it plays the role of a user in a dedicated Slack test channel, sends
each scenario's message to Navi, waits for Navi to finish, and then **judges the
outcome on three layers** — never on the reaction emoji alone:

1. **Reaction lifecycle** — necessary, not sufficient. Liveness signal only.
2. **Navi's actual thread reply** — the user-facing content.
3. **The execution Trace** in the **dev** PostgreSQL — the ground truth of what
   Navi actually did internally (rounds, nodes, delegations, tool calls, errors).

A scenario only passes when all three agree with its expected result. The agent
running this skill is the judge — that is what absorbs LLM non-determinism.

## Prerequisites

- A **Slack MCP** connected to the workspace that hosts the test channel (any of
  the `slack_*` tools: post message, read thread replies, read reactions, look
  up users).
- A **PostgreSQL MCP** (`mcp__mac-postgresql__*`) that can reach the **dev**
  environment's agent database.
- `config.md` (this skill's folder) filled in: test channel id, Navi's bot
  handle/user id, dev DB environment name, timeout.
- `scenarios.yaml` (this skill's folder): the scenarios to run, validated by
  `scenarios.schema.json`. The user keeps adding to this file after each deploy.

If a prerequisite is missing, say exactly which one and stop — do not fake a pass.

## Inputs

- Read **`config.md`** for the channel id, Navi identity, dev DB env, timeout,
  and the **report channel id** (where step 6 posts the run report).
- **Validate `scenarios.yaml` first.** From the skill folder run
  `python3 validate_scenarios.py` (needs PyYAML + jsonschema). It checks required
  fields, id format, duplicate ids, and that every `agents` name is a known agent
  (a typo fails here, not mid-run). If it exits non-zero, report the listed
  problems and stop. If Python/deps are unavailable, validate `scenarios.yaml`
  against `scenarios.schema.json` yourself before proceeding.
- Read **`scenarios.yaml`** for the scenarios (each: `id`, `title`, `message`,
  `expect`, optional `agents` list, optional `note`). If the user named specific
  scenarios in their prompt, run only those; otherwise run all.

## Workflow

Run scenarios **sequentially** (one at a time) so threads and traces don't
interleave. For each scenario:

### 1. Send
- Post as a **fresh top-level message** in the channel (NOT a reply into an
  existing thread) so it gets its own unique ts:
  `<@NAVI_USER_ID> {scenario.message}  [navi-test {run_nonce}]`
  where `run_nonce` is a short unique token per scenario (e.g. uuid8).
- Record the posted message's **ts** (from the Slack post response) and the
  **send time**. The ts is the correlation key: for a top-level message Navi
  sets `thread_ts = event.ts`, so `agent_traces.thread_ts` will equal this ts
  exactly and uniquely. The nonce is a human-traceable, last-resort confirm.

### 2. Wait for completion
- Poll every few seconds: read the **reactions** on the sent message and the
  **thread replies**.
- Navi's reaction lifecycle (exact emoji names):
  | emoji | name | meaning |
  |---|---|---|
  | 👀 | `eyes` | received / actively processing |
  | ✅ | `white_check_mark` | finished successfully |
  | ❌ | `x` | raised an unhandled error |
  | 🚫 | `no_entry_sign` | cancelled (e.g. plan rejected) |
- Stop waiting when a **terminal** reaction (`white_check_mark` / `x` /
  `no_entry_sign`) appears, or the configured **timeout** elapses.
- If Navi posts a plan and waits for approval (👀 persists, no terminal
  reaction, an interactive plan message appears): this skill does **not** click
  Slack approval buttons. To test execution, phrase the scenario message so it
  carries the human's own authorization inline (Navi supports code-verified
  direct execute). Treat a stuck-at-approval result as a finding, not a pass,
  unless the scenario explicitly expects "stops for approval".
- On **timeout with no terminal reaction** → FAIL (record "no terminal reaction
  within {timeout}s; last 👀 still present").

### 3. Collect the three layers
- **Reaction**: the terminal emoji (or none).
- **Reply**: Navi's thread reply text (the bot user's messages in the thread).
- **Trace** (the important one): query the **dev** DB. First select the dev
  environment, then correlate by the sent message ts:
  - `mcp__mac-postgresql__list_environments` / `switch_environment` → dev (see
    `config.md` for the exact env name).
  - Find the **root** trace for this exact message. The thread_ts equals the
    sent ts (confirmed: Navi sets `thread_ts = event.ts` for a top-level msg).
    Poll this query until a row appears AND its `status` is terminal (the trace
    is written asynchronously while Navi runs), up to the configured timeout:
    ```sql
    SELECT trace_id, status, round_count, duration_ms, error_message,
           agent_type, started_at
    FROM agent_traces
    WHERE thread_ts = '{sent_ts}'
      AND trace_role = 'root'        -- ignore sub-agent child traces
      AND started_at >= '{send_time}' -- freshness guard, never match a stale run
    ORDER BY started_at DESC
    LIMIT 1;
    ```
    Correlation reliability rests on four things, strongest first: (1) thread_ts
    == sent ts is exact and unique per top-level post; (2) `trace_role='root'`
    isolates the top-level trace from its sub-agent children; (3) the
    `started_at` guard rejects stale traces; (4) scenarios run sequentially, so
    only one test is ever in flight. Fallback if thread_ts somehow doesn't match:
    newest root trace with `started_at >= {send_time}` AND
    `source = 'slack_message'` AND `user_email = {test sender}`, then confirm the
    `[navi-test {run_nonce}]` marker against the trace's request context.
    Child/sub-agent traces for this run link via `parent_trace_id = {trace_id}`
    or `agent_trace_delegations.child_trace_id`.
  - Pull the flow detail for the chosen `trace_id`:
    ```sql
    -- tool calls (names, status, errors)
    SELECT round_num, tool_name, status, error_message, result_size
    FROM agent_trace_tool_calls WHERE trace_id = '{trace_id}' ORDER BY started_at;
    -- sub-agent delegations (which specialist was scheduled, and its child trace)
    SELECT requested_agent_type, resolved_agent_type, child_trace_id, task_summary
    FROM agent_trace_delegations WHERE trace_id = '{trace_id}';
    -- did each dispatched agent actually run, and finish clean? (one row per child)
    SELECT trace_id, agent_type, status, error_message
    FROM agent_traces WHERE trace_id IN ({child_trace_ids from the row(s) above});
    -- nodes traversed
    SELECT node_name, duration_ms FROM agent_trace_nodes
    WHERE trace_id = '{trace_id}' ORDER BY entered_at;
    -- failures / notable events
    SELECT event_type, event_data FROM agent_trace_events
    WHERE trace_id = '{trace_id}' ORDER BY created_at;
    ```
  - Use **read-only** SELECTs only. Never write to the dev DB.

### 4. Judge (all three must agree)
Each scenario gives a plain-language **`expect`** (what the reply should convey +
what Navi should / must not do), an optional **`agents`** list (the specialist
sub-agents that must be dispatched), and an optional **`note`**. You translate
that intent into the layered check — the scenario does **not** hand you exact tool
names or status strings, so match against intent, not literal text:
- **Reaction**: terminal success (`white_check_mark`) unless `expect`/`note` calls
  out a different terminal state (e.g. the safety gate's stop-for-approval).
- **Reply**: consistent with what `expect` says the reply should convey
  (approximate / semantic match — you are the judge).
- **Trace**: `agent_traces.status` is a clean terminal status with `error_message`
  null (unless the scenario expects otherwise); the behavior `expect` describes is
  borne out — the right kind of tools/delegations ran (follow delegations into
  child traces), and anything `expect` says **must not** happen is absent (e.g. no
  write/commit/push tools for a read-only scenario, no destructive tool for the
  safety gate). Map the human's intent onto whatever the real tool/status names
  turn out to be; never fail a scenario merely because a tool is named differently
  than you guessed.
- **Agent routing** (when `agents` is set — this assertion *is* exact, because the
  scheduled specialist is the behavior under test): for **each** agent named in
  `agents`, confirm a delegation `resolved_agent_type` matches it **and** that
  child trace actually ran with a clean terminal status (not just requested). It
  is a FAIL if an expected agent was never dispatched, its child trace errored or
  is missing, or a clearly different specialist was scheduled in its place. For a
  multi-agent fan-out, every listed agent must be present (extra agents are fine
  unless `expect` says otherwise). `agents: none` asserts the **opposite** — no
  delegation occurred and Navi answered directly; a delegation row then = FAIL.
  Note `requested_agent_type` can differ from `resolved_agent_type`; judge on
  **resolved** (what actually ran), and flag a requested≠resolved mismatch as a
  finding worth reporting.

If any layer disagrees → FAIL. A green ✅ with a wrong reply, a trace error, or the
wrong agent scheduled is still a FAIL — that's the whole point of looking past the
emoji.

### 5. (optional) Cleanup
If the scenario defines cleanup (sandbox artifacts), note it. Do not perform
destructive cleanup automatically unless the scenario says so.

### 6. Post the run report to Slack (after ALL scenarios)
Once every scenario in the run has been judged, **always** post a single report
message to the **report channel id** from `config.md` (defaults to the test
channel). This runs on every completed run — pass or fail, one scenario or many.

- Post as a **fresh top-level message** (do not reply into any scenario thread).
- The report message must **NOT** `@mention` Navi and must **NOT** contain the
  `[navi-test {nonce}]` marker — either would trigger a new Navi run or pollute
  trace correlation. Refer to Navi by plain name only.
- Use the **Slack report format** below (a compact variant of the terminal
  report — Slack markdown, trimmed replies). Keep it under Slack's size limit;
  if there are many failures, include full detail for failures and collapse
  passes to one line each.
- Keep the printed terminal report too — Slack is in addition to, not instead of.
- If posting the report fails (e.g. Slack error), report that as a finding in the
  terminal output; do not silently drop it.

## Report format

Two outputs per run: the **terminal report** (full detail, below) and the
**Slack report** (step 6 — same content, Slack-formatted and trimmed to fit).

Print a summary then per-scenario detail. For **every FAILURE** include all of:

```
SUMMARY: {passed}/{total} passed   ({duration})

FAIL — {scenario.id}: {scenario.title}
  sent:      {exact message posted to Navi}
  reaction:  {terminal emoji or "none (timeout)"}
  reply:     {Navi's actual reply, trimmed}
  trace:     trace_id={id} status={status} rounds={n} error={error_message or none}
             tools=[{tool_name:status, ...}]  delegations=[{resolved_agent_type, ...}]
  expected:  {scenario.expect (+ agents + note), in plain words}
  diverged:  {one-line diagnosis of which layer(s) disagreed and how — name the
             wrong/missing agent when routing is what failed}
```

For passes, one line each: `PASS — {id}: {title}`.

End with the overall verdict and, if anything failed, a short prioritized list of
what to investigate.

### Slack report (step 6)

Post this to the report channel. Same facts as the terminal report, Slack
markdown, replies trimmed to one line. Skipped scenarios (unfilled `<FILL>` /
missing sandbox ids) get their own line so coverage gaps are visible.

```
*Navi smoke test* — {passed}/{total} passed   ({duration}, {dev DB env})

{✅ or ⚠️} *Verdict:* {one line — all green / N failed}

*Passed:* {id1}, {id2}, …
*Failed:*
• *{id}: {title}*
   reaction {emoji} · reply: {trimmed reply}
   trace `{trace_id}` status={status} rounds={n} error={error or none}
   tools=[{tool:status, …}] delegations=[{resolved_agent_type, …}]
   diverged: {which layer(s) disagreed and how}
*Skipped:* {ids} — {reason, e.g. unfilled <FILL> / no sandbox ids}

{if failures: *Investigate first:* {1–2 prioritized items}}
```

If everything passed, drop the `*Failed:*` block. If nothing was skipped, drop
`*Skipped:*`.

## Safety

- Scenarios run against the deployed bot and may execute real actions; keep them
  scoped to the configured **sandbox** (see `config.md`).
- The dev DB is queried **read-only**.
- Never invent a trace or a reply. If the trace can't be found, report that as a
  finding (it may itself indicate a logging/wiring regression).
