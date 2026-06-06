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
  `expect`, optional `agents` list, optional `note`, optional `in_thread_of`). If
  the user named specific scenarios in their prompt, run only those; otherwise run
  all.
- **`in_thread_of` (thread dependency).** A scenario with `in_thread_of: T-0XX`
  is **not** sent as a fresh top-level message — it is posted as a reply **inside
  the Slack thread of the referenced scenario**, to test multi-turn / context
  continuation (e.g. T-004 creates a ticket, then T-005 `in_thread_of: T-004`
  says "assign it to me" relying on the thread's context). The reference always
  points at a scenario defined **earlier** in the file (validated). When you run a
  **subset**, a threaded scenario needs its `in_thread_of` ancestor to have run
  first **in the same session** — auto-include the ancestor chain and run it
  top-to-bottom so the parent thread exists; if an ancestor cannot be run, report
  that and skip the dependent rather than silently posting it top-level.

## Workflow

Run scenarios **sequentially** (one at a time) so threads and traces don't
interleave. For each scenario:

### 1. Send
- Build the text as `<@NAVI_USER_ID> {scenario.message}  [navi-test {run_nonce}]`
  where `run_nonce` is a short unique token **per scenario** (e.g. uuid8). The
  nonce is what correlates this exact message to its trace — keep it unique even
  for threaded scenarios.
- **Default (no `in_thread_of`):** post as a **fresh top-level message** (NOT a
  reply into an existing thread) so it gets its own unique ts.
- **Threaded (`in_thread_of: T-0XX`):** post as a **reply into the referenced
  scenario's thread** — `slack_send_message` with `thread_ts =` the **thread-root
  ts you recorded** for `T-0XX` (see below). This makes Navi handle it as a
  follow-up turn with the thread's prior context.
- Record, per scenario id, the posted message's own **ts**, the **send time**,
  and the **thread-root ts** to thread future replies under:
  - top-level scenario → thread-root ts = its own posted ts (Navi sets
    `thread_ts = event.ts`, so `agent_traces.thread_ts` equals it exactly).
  - threaded scenario → thread-root ts = **inherited** from its `in_thread_of`
    ancestor (Slack flattens nested replies into one thread:
    `thread_ts = event.thread_ts = root`). So a later scenario may thread off
    this one and still land in the same root thread.
- ⚠️ For a threaded scenario, `agent_traces.thread_ts` is the **shared root ts**,
  NOT this message's own ts — so it is NOT a unique key. Correlate threaded
  scenarios by the **nonce** instead (step 3).

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
- **Reaction**: read reactions on **this scenario's own posted ts** (Navi reacts
  on the exact message it received, so this is correct even inside a shared
  thread). Take the terminal emoji (or none).
- **Reply**: Navi's reply text in the thread. For a **threaded** scenario the
  thread is shared with the ancestor, so attribute the reply to THIS turn: take
  the bot user's message(s) in the thread with `ts > {this scenario's posted ts}`
  (posted after your send). Sequential execution guarantees no other test is
  interleaving.
- **Trace** (the important one): query the **dev** DB. First select the dev
  environment, then correlate — **the key differs for top-level vs threaded**:
  - `mcp__mac-postgresql__list_environments` / `switch_environment` → dev (see
    `config.md` for the exact env name).
  - **Top-level scenario** — correlate by the sent ts (`thread_ts == sent ts`,
    exact and unique). Poll until a row appears AND its `status` is terminal (the
    trace is written asynchronously while Navi runs), up to the configured
    timeout:
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
  - **Threaded scenario (`in_thread_of`)** — `thread_ts` is the **shared root ts**
    (`event.thread_ts`), so it can't distinguish this turn from its ancestor/
    siblings. Correlate by the **nonce**, which Navi stores verbatim in
    `metadata_json->>'user_request'` (the user's message text, nonce included):
    ```sql
    SELECT trace_id, status, round_count, duration_ms, error_message,
           agent_type, started_at
    FROM agent_traces
    WHERE trace_role = 'root'
      AND started_at >= '{send_time}'            -- freshness guard
      AND metadata_json->>'user_request' LIKE '%[navi-test {run_nonce}]%'
    ORDER BY started_at DESC
    LIMIT 1;
    ```
  - Reliability rests on, strongest first: (1) the nonce is unique per scenario
    message and embedded in `user_request`, so it pins the exact run even in a
    shared thread; for top-level, thread_ts == sent ts is an equally exact key;
    (2) `trace_role='root'` isolates the top-level trace from its sub-agent
    children; (3) the `started_at` guard rejects stale traces; (4) scenarios run
    sequentially, so only one test is ever in flight. The nonce query is also the
    universal **fallback** if the top-level thread_ts somehow doesn't match.
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

Post this to the report channel. Same facts as the terminal report, but built for
Slack mrkdwn so it stays scannable. **Follow this structure literally — one fact
per labelled line. Do NOT write the report as flowing prose paragraphs** (that is
what makes a run unreadable). Render exactly like this:

```
*Navi smoke test — {passed}/{total} passed*   ·   {duration} · {dev DB env}

{✅ | ⚠️} *Verdict:* {one line — "all green" or "N failed, M are real bugs vs scenario drift"}

✅ *Passed ({k})*
• {id} — {title} ({3–6 word why, e.g. "no delegation, as asserted"})

❌ *Failed ({n})*

*{id} — {title}*
• reaction: {emoji}   ·   reply: {reply trimmed to ONE line}
• trace: {trace_id} — {status}, {n} rounds, {error_message or "no error"}
• routing: {resolved agents that ran, or "none — answered inline"}
• expected: {scenario.expect in plain words, incl. agents/note}
• diverged: {which layer(s) disagreed and how — name the wrong/missing agent}

⏭️ *Skipped ({s})*
• {id} — {reason, e.g. unfilled <FILL> / no sandbox ids}

🔎 *Investigate first*
1. {prioritized item}
2. {prioritized item}
```

Rendering rules (these are what keep it clean — the screenshot bug was breaking
all of them):
- **Emojis appear in only two places**: the `Verdict:` line, and after the
  `reaction:` label. Never drop a ✅/❌/👀 into the middle of a sentence — a reader
  can't tell whether it means "passed" or "the reaction was green". The per-section
  ✅ *Passed* / ❌ *Failed* headers carry the verdict; individual scenarios don't
  repeat it.
- **Backticks only for a real identifier** you'd copy-paste (a `trace_id`). Do NOT
  wrap tool names, agent names, status words, repo paths, or `agents=[…]` in
  backticks — that grey-box noise is what made the old report unreadable. Write
  them as plain words: `routing: none — answered inline (execute_direct_capability)`.
- **One fact per `•` line.** Don't pack reaction + reply + trace + diagnosis into a
  single run-on line. Each failed scenario is a small block of labelled lines.
- **Trim the reply to one line** (~one sentence). If it was an error/404, say so in
  plain words and quote just the key fragment, not the whole payload.
- Put a blank line between failed-scenario blocks so they don't visually merge.

Drop any section that's empty: no failures → drop ❌ *Failed* and 🔎 *Investigate
first*; nothing skipped → drop ⏭️ *Skipped*. If everything passed, the whole
report is just the title, a ✅ verdict, and the ✅ *Passed* list.

## Safety

- Scenarios run against the deployed bot and may execute real actions; keep them
  scoped to the configured **sandbox** (see `config.md`).
- The dev DB is queried **read-only**.
- Never invent a trace or a reply. If the trace can't be found, report that as a
  finding (it may itself indicate a logging/wiring regression).
