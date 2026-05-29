# ci-deploy — Design

**Date:** 2026-05-29
**Author:** Norman
**Status:** Approved for planning

## Goal

Turn the Navi-specific `deploy-dev` skill into a portable, project-agnostic
skill named **`ci-deploy`** that lives in the `Norman-else/awesome-skills`
plugin repo and installs directly into both Claude Code and Codex. Any repo
that deploys via a CircleCI manual-approval gate should be able to use it with
zero per-repo configuration.

## Why this is feasible

The existing `deploy_dev.sh` is already ~95% generic. The only project-specific
parts are six constants at the top:

- `PROJECT_SLUG="gh/Mercaso/Navi"`
- `WORKFLOW_NAME="navi-pipeline"`
- `APPROVAL_JOB_NAME="hold_dev"`
- `DEPLOY_JOB_NAME="deploy_dev"`
- `TEST_JOB_NAME="build_and_test"`

Everything else (CircleCI API v2 calls, the poll/approve/monitor state machine,
exit-code contract) is reusable as-is. Generalization = replace those constants
with auto-detection + arguments, de-Navi the prose, and add a Codex companion.

## Auto-detection (CircleCI-native, no GitHub dependency)

| Item | Source |
|------|--------|
| token | `$CIRCLECI_TOKEN` → `~/.circleci/cli.yml` (unchanged) |
| project slug | parse `git remote get-url origin` → `gh/OWNER/REPO` (SSH + HTTPS; GitHub→`gh`, Bitbucket→`bb`) |
| target commit | default = remote tip of the **current branch**; `--sha <sha>` overrides |
| branch | `git rev-parse --abbrev-ref HEAD` |
| pipeline | `GET /project/{slug}/pipeline?branch={branch}`, match `vcs.revision == SHA` |
| workflow | single → use it; multiple → pick the one containing the target deploy job; `--workflow <name>` overrides |
| deploy job | regex `(deploy\|release\|ship\|publish)[-_]?{env}` or `{env}[-_]?(deploy\|release)` |
| approval gate | approval-type job (reaches `on_hold`) matching `{env}`, or named hold/approve/gate + `{env}` |
| test gate | the remaining non-deploy / non-approval jobs; any `failed` ⇒ build failed |

The GitHub-checks-driven detection idea was rejected as the primary path:
manual-approval gates do **not** post a GitHub status check (they never
execute), so the approval job would be invisible. CircleCI's
`/workflow/{id}/job` endpoint returns the gate, so the CircleCI-native path is
both simpler (one auth system) and complete.

### No config-file fallback

All target repos name deploy jobs with the environment embedded
(`deploy_dev`, `deploy_sat`, …), so the naming convention is sufficient. No
`.claude/circleci-deploy.json` is introduced. The only safety net is
agent-resolved disambiguation via exit codes (below) — zero files for the user
to maintain.

## Target environment resolution

- **Env given explicitly** (`deploy dev`, `ship to sat`) → use it.
- **Env omitted** (`deploy this`, `部署一下`) → scan all `deploy_*` jobs, derive
  the candidate env list:
  - exactly one env → use it, no prompt.
  - **multiple envs** (e.g. `deploy_dev` + `deploy_sat`) → exit **10** and print
    the env list; the agent asks the user (AskUserQuestion) and re-runs with the
    chosen env.
- **Env given but matches multiple deploy jobs** (`deploy_dev` + `deploy_dev_canary`)
  → exit **9** and print candidates; the agent resolves with explicit
  `--deploy-job` / `--approval-job` / `--test-job`.

## CLI surface

```
deploy.sh [<env>] [--sha <sha>] [--workflow <name>]
          [--deploy-job <name>] [--approval-job <name>] [--test-job <name>]
          [--no-autofix]
```

- `<env>` — optional positional target environment (e.g. `dev`, `sat`, `prod`).
- `--sha` — target a specific commit instead of the current branch's remote tip.
- `--workflow` — pin the workflow when a pipeline has several.
- `--deploy-job` / `--approval-job` / `--test-job` — explicit overrides used by
  the agent when detection is ambiguous (exit 9).
- `--no-autofix` — informational; the auto-fix loop lives in the agent, not the
  script. Reserved for parity / future use.

## Exit codes

Existing contract preserved, two new codes added:

| Code | Meaning |
|------|---------|
| 0 | deploy succeeded (or already success on re-run) |
| 2 | missing CircleCI token |
| 3 | no pipeline found for SHA yet |
| 4 | workflow not found |
| 5 | test job failed → agent enters auto-fix loop |
| 6 | deploy job failed (this run or a prior run for the SHA) |
| 7 | tests never reached on_hold within the poll ceiling |
| 8 | deploy job didn't finish within the poll ceiling |
| **9** | **detection ambiguous — multiple jobs match; re-run with explicit `--*-job`** |
| **10** | **env omitted and multiple deploy environments exist — agent must ask the user which** |

## Auto-fix loop

Retained and **on by default** (per decision). De-Navi'd in SKILL.md:

- On exit 5, the agent fetches failed step output, diagnoses, applies the
  smallest fix, commits, and pushes to the **current branch** (not hardcoded
  `master`), then re-runs.
- Navi-specific references generalized: `requirements*.txt` → "the project's
  dependency manifest".
- Stop conditions kept verbatim (≥5 iterations, same root cause twice,
  infra-level failure, decision-required, flaky, tests-never-ran).

## Files

Under `plugins/awesome-skills/skills/ci-deploy/`:

1. `SKILL.md` — generalized triggers ("deploy to <env>", "部署 dev/sat/prod",
   "ship to staging"), env-arg docs, auto-detection explanation, the auto-fix
   loop, exit-code table incl. 9 and 10.
2. `scripts/deploy.sh` — generalized `deploy_dev.sh`: arg parsing +
   auto-detection replace the six constants; state machine and monitor reused;
   adds exit 9/10.
3. `scripts/fetch_failed_logs.sh` — generalized: `PROJECT_V1` derived from git
   remote (`github/OWNER/REPO`) instead of hardcoded `github/Mercaso/Navi`.
4. `agents/openai.yaml` — Codex companion, mirroring `vault-share/agents/openai.yaml`
   (interface block; no MCP dependency — the skill uses bash/curl/python3).

## Repo bookkeeping

- Bump plugin version `0.1.2 → 0.1.3` in both `.claude-plugin/plugin.json` and
  `.codex-plugin/plugin.json`, plus the marketplace manifest.
- Add a `ci-deploy` example to `.codex-plugin/plugin.json` `defaultPrompt`.
- Add a README line for `ci-deploy`.

## Non-goals

- Staging/prod safety policies beyond what the user's CircleCI gate already
  enforces (the gate IS the control).
- Non-CircleCI CI systems.
- GitHub-checks detection (rejected above).
- Persisted per-repo config files.
