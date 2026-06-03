# navi-testing config

Fill these in for your environment. The skill reads this file at the start of a run.

## Slack

- **Workspace**: Mercaso
- **Test channel name**: `navi-automation-testing`
- **Test channel id**: `C0B7YGB706M`
- **Navi bot @handle**: `@Navi`  <!-- used in the message text -->
- **Navi bot user id**: `U0ANZ20J85Q`  <!-- e.g. U0XXXXXXX; if blank, the skill
     resolves it by looking up the "Navi" bot in the workspace users -->
- **Test sender email**: `<FILL ME>`  <!-- the human/identity the skill posts as;
     used as a fallback key to correlate the trace (agent_traces.user_email) -->
- **Report channel id**: `C0B7YGB706M`  <!-- where the end-of-run report is posted
     (step 6). Defaults to the test channel itself. Set to a different channel id or
     a user id (DM) to send the report elsewhere. The report is posted as a plain
     top-level message and must NOT @mention Navi (would trigger a new run). -->

## Dev database (PostgreSQL MCP)

- **MCP**: `mcp__mac-postgresql__*`
- **Environment name for dev**: `<FILL ME>`  <!-- run list_environments to see the
     exact name, then switch_environment to it before querying -->
- Query **read-only**. Trace tables: `agent_traces`, `agent_trace_nodes`,
  `agent_trace_delegations`, `agent_trace_llm_calls`, `agent_trace_tool_calls`,
  `agent_trace_events`. Correlate by `agent_traces.thread_ts = <sent message ts>`
  (and `trace_role = 'root'`, `started_at >= <send time>`).

## Run settings

- **Per-scenario timeout**: `180` seconds (raise for heavy scenarios).
- **Poll interval**: `5` seconds.
- **Sandbox**: scenarios must stay within the test sandbox (test Jira project /
  repo / env). Note the sandbox identifiers here so scenarios can reference them:
  - Sandbox Jira project: `<FILL ME>`
  - Sandbox repo / env: `<FILL ME>`
