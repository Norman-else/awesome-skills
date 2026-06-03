# navi-testing scenarios

Add a scenario after each deploy. Keep each one self-contained and sandbox-safe.
The skill runs them top to bottom and judges each on all three layers
(reaction + reply + dev trace).

## Scenario template (copy this)

````
### {id}: {short title}
- **message**: the exact text to send (the skill prepends `@Navi` + a nonce)
- **expected_result**: plain-language description of what Navi's reply should
  convey (approximate / semantic — the agent judges it)
- **expected_flow**: what the dev trace should show — terminal `status`, expected
  tools / sub-agent delegations / nodes, and that there are no unexpected errors
- **expected_reaction**: white_check_mark (default) | x | no_entry_sign
- **notes / cleanup**: sandbox scoping, anything to clean up afterward (optional)
````

---

## Seeded examples (edit/replace with your real ones)

### smoke-001: basic liveness Q&A (read-only)
- **message**: What can you help me with? Give a one-line answer.
- **expected_result**: A short, coherent capability summary. No error, no tool
  execution needed.
- **expected_flow**: trace `status = succeeded` (or your success status),
  `round_count >= 1`, no `error_message`, no tool calls with `status != 'ok'`.
- **expected_reaction**: white_check_mark
- **notes**: pure liveness — proves message → LLM → reply works end to end.

### smoke-002: tool path (read-only query)
- **message**: List the open PRs you can see for the sandbox repo. Don't change anything.
- **expected_result**: A reply listing PRs (or clearly stating none/no access),
  not an error.
- **expected_flow**: trace shows the expected query/tool call(s) with
  `status = 'ok'`; `agent_traces.status` terminal-success; no unexpected errors.
- **expected_reaction**: white_check_mark
- **notes**: read-only; verifies the tool layer + provider creds are wired.

### smoke-003: sandbox execution (real action, sandbox only)
- **message**: Create a test Jira ticket titled "navi smoke {date}" in the sandbox
  project. Go ahead and do it.
- **expected_result**: Reply confirms a Jira ticket was created, with the issue
  key / link.
- **expected_flow**: trace shows a Jira create tool call with `status = 'ok'`
  (and/or a delegation to the right agent_type); `agent_traces.status`
  terminal-success; no `error_message`.
- **expected_reaction**: white_check_mark
- **notes**: SANDBOX ONLY. Phrase carries inline authorization so it executes
  without a button click. Cleanup: optionally delete/close the created ticket.
