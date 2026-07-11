---
name: ci-deploy
description: Use whenever the user asks to deploy a project to an environment through a CircleCI manual-approval gate — phrases like "deploy to dev", "ship to staging", "release to prod", "deploy this", or naming a repo you haven't cloned ("deploy backend delivery to sat"). Auto-detects the CircleCI project, workflow, and approval/deploy/test jobs from the current git repo (no per-repo config); also supports a remote mode that deploys a repo you have not cloned by resolving it from a natural-language name via `gh`. Approves the gate for the chosen environment, waits for tests if needed, then watches the deploy job until it succeeds or fails. Do NOT use for local docker runs or any deploy that doesn't go through a CircleCI approval gate.
---

# Deploy to an environment via CircleCI

This skill approves a CircleCI manual-approval gate for a chosen environment and
watches the resulting deploy job. It is project-agnostic: it discovers the
CircleCI project, workflow, and job names automatically, so the same skill works
across every repo whose pipeline gates deploys behind a manual approval.

## Invoking with no input IS a deploy request

When this skill is invoked with no extra prompt or arguments, treat the
invocation itself as "deploy now". Do NOT ask the user for a prompt or a target
environment first — go straight to running the script (in the background) and
let environment resolution handle the rest:

- Run `deploy.sh` with no environment argument.
- If the repo has exactly one deploy environment, it deploys that one.
- If it has several, the script exits **10** and prints `DEPLOY_ENVS=...`; only
  then ask the user which environment (with AskUserQuestion) and re-run with it.

A prompt/argument is optional — it only narrows the target when given (e.g.
"deploy to sat"). Its absence is not a reason to stop and ask.

## When this triggers

Direct requests to deploy a project to some environment:
- "deploy to dev" / "ship to staging" / "release to prod"
- "deploy this" (environment resolved automatically — see below)
- naming a repo you haven't cloned — "deploy backend delivery to sat" (remote
  mode — see "Deploying a repo you haven't cloned" below)

When NOT to trigger:
- Local `docker compose up` or running the app locally.
- "How do I deploy?" — that's a documentation question; explain the steps instead.
- Pipelines with no manual approval gate where there's nothing to approve.

## Resolving the target environment

- **User named an environment** ("deploy dev", "ship to sat") → that environment.
- **User did not name one** ("deploy this") → the script inspects the workflow's
  deploy jobs:
  - exactly one deploy environment → it's used automatically, no prompt.
  - **multiple environments** (e.g. `deploy_dev` + `deploy_sat`) → the script
    exits **10** and prints `DEPLOY_ENVS=dev,sat`. Ask the user which one with
    AskUserQuestion, then re-run with the chosen environment.

## Cascading through prerequisite environments

Most pipelines gate environments in a chain — `build → hold_dev → deploy_dev →
hold_sat → deploy_sat → hold_prod → deploy_prod` — where a later environment's
approval gate only opens once the earlier deploy has succeeded. Asking to deploy
`prod` on a fresh pipeline therefore can't just approve `hold_prod`; that gate is
still blocked behind `dev` and `sat`.

The script handles this automatically. It derives the full prerequisite chain to
the target from the workflow's job dependency graph and walks it in order:
approve `hold_dev` → watch `deploy_dev` → approve `hold_sat` → watch `deploy_sat`
→ approve `hold_prod` → watch `deploy_prod`. **This is hands-off — it actually
deploys every prerequisite environment on the way to the target**, in one
background run. Stages already deployed (gate approved, deploy succeeded) are
skipped, so it stays idempotent on re-runs and partial pipelines.

Single-environment pipelines (one deploy job, like a dev-only repo) are just a
one-stage chain — behaviour is unchanged.

### Multiple approval gates per stage (auto-detected)

A stage isn't limited to a single gate. Some pipelines guard one environment with
**several sequential approvals** — e.g. `hold_build_prod → build_prod → hold_prod
→ deploy_prod`, where the first gate releases the build and the second releases
the deploy. The script derives the **complete ordered set of approval gates** on
each deploy job's dependency path straight from the graph (no per-repo config) and
clears them one at a time: approve `hold_build_prod` → wait for `build_prod` →
approve `hold_prod` → watch `deploy_prod`. This generalises to any workflow shape:

- one gate per deploy (the common `hold_x → deploy_x`) → approve the one gate;
- several sequential gates → approve each in dependency order, waiting for each to
  open (a later gate often stays `blocked` until the earlier one's build runs);
- no gate (auto-deploy) → approve nothing, just watch the deploy;
- cascaded stages → each stage clears only its own gates; a prerequisite env's gate
  is never re-approved under a later env.

Because the gate set is graph-derived, **multiple env-matching approval jobs are no
longer an exit-9 ambiguity** — they're simply that stage's gate list. `--approval-job`
still overrides the target stage when you need to pin one explicitly.

**Announce the plan.** The script prints a `Cascade: dev → sat → prod` line once
it resolves the chain (it appears early in the background output). When the chain
has more than one stage, relay it to the user up front so they know prod will be
preceded by automatic dev + sat deploys.

## How to run it

Invoke the bundled script. It is idempotent and safe to re-run.

```bash
.claude/skills/ci-deploy/scripts/deploy.sh <env>
```

On Windows PowerShell, invoke the bundled wrapper instead. It finds Git Bash,
reads the Windows CircleCI CLI token if needed, and forwards all arguments to
`deploy.sh`:

```powershell
.\.claude\skills\ci-deploy\scripts\deploy.ps1 <env>
```

`<env>` is optional (see resolution above). Useful options:

```bash
deploy.sh <env> --repo <owner/repo>     # remote mode: deploy a repo you haven't cloned
deploy.sh <env> --branch <name>         # override the branch (remote mode defaults to master)
deploy.sh <env> --sha <commit>          # target a specific commit instead of the branch tip
deploy.sh <env> --workflow <name-or-id>  # pin the workflow when a pipeline has several
deploy.sh <env> --deploy-job <name>     # explicit deploy job (resolves exit-9 ambiguity)
deploy.sh <env> --approval-job <name>   # explicit approval gate
deploy.sh <env> --service <name>        # monorepo: deploy ONE service (see Monorepo service mode)
deploy.sh <env> --service-path <glob>   # override the service's source path (default services/<name>)
deploy.sh <env> --yes                   # skip the foreign-commit confirmation gate (exit 12)
deploy.sh <env> --test-job <name>       # restrict the "build failed" check to one job
deploy.sh <env> --rerun                 # cancel + rerun the workflow from START, then watch the fresh run
deploy.sh <env> --rerun-from-failed     # cancel + rerun only failed jobs + downstream, then watch
```

The path above assumes the skill is installed into a project's `.claude/skills/`.
When run from the plugin cache, use the script's own absolute path — the script
resolves its sibling `detect.py` relative to itself either way.

## Ownership check (exit 12)

Before deploying, the script prints an **ownership summary** for the resolved
pipeline: who triggered it, the commit author + subject, and — for monorepos —
which services the commit changed. (The `run-*-build` parameter *values* are not
exposed by the CircleCI API, so changed services are derived from the commit's
`services/<name>/` paths, which is exactly what path-filtering keys off; a
non-monorepo simply has no such paths and shows none.)

If the target commit's author is **not the current user** and `--yes` was not
passed, the script stops with **exit 12**. On exit 12: show the user the
triggered-by actor, the commit subject, and the changed services, and ask them to
confirm. Only after they approve, re-run the exact same command with `--yes`
appended. Never pass `--yes` pre-emptively.

## Monorepo service mode (--service)

Some repos are **monorepos** that build and deploy several services from one
path-filtered CircleCI pipeline — each service is (re)built only when its own files
change. `accounting-service`, `item-management-service`, … are *services inside*
`premier-store-os`, **not** standalone repos. For these:

- Do **not** `gh search repos` for the service name — it is not a repo.
- Do **not** target the branch tip. A tip pipeline that changed a *different*
  service halts this service's deploy job into a green no-op (now caught as exit 11).

Name the service with `--service` instead:

```bash
# from inside the monorepo clone
deploy.sh sat --service accounting-service
# or without a clone
deploy.sh sat --repo Mercaso/premier-store-os --service accounting-service
```

`--service X` resolves:

1. **Jobs** — `deploy_<X>_<env>` and gate `hold_<X>_<env>` by convention (override
   with `--deploy-job` / `--approval-job`, or the per-repo config below). Requires
   an environment argument.
2. **Target commit** — unless `--sha` is given, the latest commit on the branch that
   changed the service's path (`services/<X>/` by default, or `--service-path`), so
   the pipeline that actually built the service is chosen.

### Optional per-repo config

Drop `.claude/ci-deploy.json` in the monorepo root to declare a non-default layout
(templates use `{service}` and `{env}`):

```json
{
  "service_path": "services/{service}",
  "deploy_job": "deploy_{service}_{env}",
  "approval_job": "hold_{service}_{env}"
}
```

The defaults above already match `premier-store-os`, so the file is optional there.

## Deploying a repo you haven't cloned (remote mode)

When the user names a repo they have **not** cloned — e.g. "deploy backend
delivery to sat" — resolve the repo and the target commit with `gh`, then hand
an explicit slug + commit to the script. This requires an authenticated `gh`
CLI. The default GitHub org is **`Mercaso`**.

1. **Resolve the repo from the description.** Search the org:
   ```bash
   gh search repos --owner Mercaso "<description>" --limit 10 --json fullName,description
   ```
   - **Exactly one strong match** → use it; tell the user which repo you picked
     when you start the deploy.
   - **Several plausible matches** → ask the user which one with AskUserQuestion.
   - **No match** → tell the user, ask them to refine the description.
   - If the user already gave an explicit `owner/repo`, skip the search. The org
     defaults to `Mercaso` only when the user gives a bare name; an explicit
     owner always wins.

2. **Resolve the target commit — the user's latest commit on `master`.** Filter
   by GitHub **author** (committer changes under rebase/squash):
   ```bash
   login=$(gh api user --jq .login)
   gh api "repos/<owner>/<repo>/commits?sha=master&author=$login&per_page=1" --jq '.[0].sha'
   ```
   - Got a SHA → deploy that commit.
   - **Empty** (the user has no commit on `master`) → tell the user; offer to
     deploy the plain `master` tip instead (drop `--sha`), or stop.

3. **Deploy.** Run in the background, same as local mode:
   ```bash
   deploy.sh <env> --repo Mercaso/<repo> --branch master --sha <sha>
   ```
   Environment disambiguation (exit 10) and every other exit code behave exactly
   as in local mode.

**No clone means no auto-fix loop.** The exit-5 auto-fix loop below commits and
pushes fixes, which needs a local working copy. In remote mode there is none, so
on **exit 5** fetch the failed logs (`fetch_failed_logs.sh`) and report the
failure — do **not** enter the commit/push loop. If the user wants the build
fixed, tell them a local clone is required first.

### What it auto-detects

- **Project slug** from `git remote get-url origin` (GitHub → `gh/`, Bitbucket → `bb/`).
- **Target commit**: the current branch's remote tip by default (`--sha` overrides).
- **Pipeline**: the CircleCI pipeline whose revision matches the target commit on
  the current branch.
- **Workflow**: the workflow in that pipeline containing a deploy job (`--workflow` to pin by name or workflow ID).
- **Deploy / approval / test jobs**: by naming convention — a deploy job is
  `deploy_<env>` / `deploy-<env>` / `release-<env>` etc.; the approval gate is the
  approval-type job matching the environment; everything else is a build/test job.

### Run it in the background

The script runs in two phases per stage: it waits for the build/test jobs (~2–4 min
typical, up to ~13 min ceiling), approves the gate, then watches the deploy job
until it finishes (~3–8 min typical, up to ~20 min ceiling). A single-environment
deploy is usually under 15 minutes. **A cascade multiplies this by the number of
prerequisite environments** — deploying `prod` through `dev` + `sat` runs three
deploy stages back-to-back, so budget proportionally longer. Always run it in the
background — you'll be notified when it completes, then you can report success or
surface the failure.

When telling the user what you're doing, name the environment and the commit
(short SHA). The script prints the workflow URL once it locks onto a pipeline;
include that link so the user can watch in parallel. When the script exits, its
final lines say whether the deploy succeeded or how it failed — relay that.

## When the build fails: auto-fix loop

Exit code 5 means a build/test job failed. Treat this as part of the normal deploy
flow, not a stopping point — the user invoked this skill to get a deploy *out*, not
just to learn the build broke. Run the loop below until the deploy succeeds, or
until one of the explicit stop conditions hits.

**Remote mode (`--repo`, no local clone) skips this loop entirely** — there is no
working copy to edit, commit, or push. On exit 5 in remote mode, fetch the failed
logs and report the failure (see "Deploying a repo you haven't cloned"); offer a
local clone if the user wants it fixed.

The loop is your responsibility, not the script's. The script does deploy
mechanics; you do diagnosis, fix, and retry. Re-running `deploy.sh` after each fix
automatically picks up the new tip of the current branch.

### One iteration

1. **Grab the workflow ID.** The script's background-output file contains a line
   like `Workflow: a50e082f-…`. Read the file (the path is in the task
   notification you got) and extract that UUID. It's how you fetch logs.

2. **Fetch the failed step output.** Run:
   ```bash
   .claude/skills/ci-deploy/scripts/fetch_failed_logs.sh <workflow-id>
   ```
   On Windows PowerShell, use:
   ```powershell
   .\.claude\skills\ci-deploy\scripts\fetch_failed_logs.ps1 <workflow-id>
   ```
   With no job name it inspects every failed job and tails each failed step to
   ~300 lines, so you read the actual diagnostic, not 50k lines of resolver
   chatter. Override with `TAIL_LINES=N`, or pass a job name as the 2nd arg.

3. **Diagnose the root cause.** Common shapes:
   - **Test assertion / `StopIteration` / `AttributeError`** — actual code or test
     bug. `StopIteration` from a `MagicMock` almost always means a mock's
     `side_effect` list is too short because a new code path was added without
     updating the mock.
   - **Import / `ModuleNotFoundError`** — broken module path or missing dep. Check
     the project's dependency manifest and the import statement.
   - **Type / lint** — file + line is right there in the message. Fix it.
   - **Infrastructure flake** (network timeout, container 137, "checkout failed") —
     *not* something you patch in code. See stop conditions.

4. **Apply the smallest fix.** Don't add features, don't refactor, don't widen the
   change beyond what the failure needs. Don't bypass tests with `--no-verify`,
   `xfail`, `pytest.skip`, or `# type: ignore` unless the user explicitly asked.

5. **Commit and push.** One focused commit, message like `Fix <thing> caught by
   CI`. Push to the **current branch** (the branch the deploy targets).

6. **Re-run the deploy script in the background.** It auto-targets the current
   branch's new tip, so your fix gets picked up. Wait for the task notification.

7. **On exit 0** → deploy succeeded, report success.
   **On exit 5 again** → loop back to step 1, reading the *new* logs, not your
   memory of the old failure.
   **On exit 6, 7, 8** → see "Other exit codes" below.

Give the user one tight update per iteration: which commit you pushed, what you
fixed, the new workflow URL. Don't narrate every poll.

### Stop conditions (do NOT keep looping)

Pause and ask the user the moment any of these hit:

- **Iteration count ≥ 5.** Hard ceiling. If five fixes haven't gotten a green
  build, something deeper is wrong.
- **Same root cause two iterations in a row.** Your fix isn't working.
- **Infrastructure-level failure** with no per-step output, or `fetch_failed_logs.sh`
  reports no failed steps. Likely a CI runner issue, not code.
- **Failure requires a decision you can't make** (e.g. an API contract changed and
  the test asserts the old shape — which side is correct is a product call).
- **Failure looks flaky** (network blip, timing-sensitive test). Don't "fix"
  something that wasn't broken; offer to retry without a code change.
- **The build/test jobs never ran** (exit 3 or 4): the pipeline didn't ingest the
  commit or the workflow filter rejected the branch. Don't loop — investigate.

## Detection ambiguity (exit 9 / 10)

- **Exit 10** — environment omitted and multiple deploy environments exist. The
  script prints `DEPLOY_ENVS=...`. Ask the user which environment with
  AskUserQuestion, then re-run with that environment as the first argument.
- **Exit 9** — multiple jobs match (e.g. `deploy_dev` and `deploy_dev_canary`, or
  several workflows have deploy jobs). The script prints the candidates. Pick the
  right one and re-run with `--deploy-job` / `--approval-job` / `--workflow`. If
  it's genuinely unclear which is correct, ask the user. **Note:** multiple
  *approval gates* on a stage's path are NOT an exit-9 case — they're auto-detected
  and approved in order (see "Multiple approval gates per stage" above). Exit 9 is
  only for ambiguous **deploy jobs** or **workflows**.
- **Re-runs are handled automatically — they no longer trip exit 9.** When a
  pipeline holds several workflow *runs of the same name* (CircleCI leaves the
  superseded runs `canceled` after a "rerun from beginning/failed"), the script
  drops the canceled runs and keeps the single live run, so the duplicate-name
  reruns collapse to one candidate. Only genuinely *distinct* workflows (different
  names) still surface as exit 9 and need `--workflow`. This means a partially
  approved rerun (e.g. `deploy_dev` already succeeded, `hold_sat`/`hold_prod` still
  on hold) resumes cleanly on a re-invoke.

## Other exit codes

- **Exit 6** (deploy job failed) — the build was fine but a deploy broke. In a
  cascade the failing stage may be a prerequisite, not the target: the script's
  stderr names it (`deploy failed at env 'sat' — cascade stopped before prod`),
  and later stages are left untouched. Fetch the failed deploy-job logs with the
  job name:
  ```bash
  .claude/skills/ci-deploy/scripts/fetch_failed_logs.sh <workflow-id> <deploy-job-name>
  ```
  Don't auto-retry — deploy failures often indicate environment drift (missing
  secret, image push failure, infra service down) and need eyes on them. **Once
  the root cause is fixed** (the secret added, the image pushed, the policy
  granted), rerun the deploy with `--rerun` rather than manually poking CircleCI —
  see "Rerunning a workflow" below.
- **Exit 7 / 8** — timeouts. Don't blindly retry; surface to the user.

## Rerunning a workflow (`--rerun` / `--rerun-from-failed`)

A deploy job that has already failed sits in a **terminal `failed` state**. Plain
re-invocation of `deploy.sh` will *not* retry it — `run_stage` sees the terminal
failure on its first poll and returns exit 6 immediately. To actually re-run the
deploy you must trigger a CircleCI rerun, and the script does this for you:

- `--rerun` — **rerun from the start.** Cancels the current run, waits for it to
  reach a terminal state, triggers a fresh full run, and switches to watching the
  new workflow id. Build/test jobs re-run and the approval gates re-open (the
  cascade re-approves them). This is the right choice after fixing an external
  cause of a deploy failure, because it discards any stale/cached run state — a
  `--rerun-from-failed` can re-fail instantly by reusing the same bad state.
- `--rerun-from-failed` — **rerun only the failed jobs + their downstream.** Reuses
  upstream successes and already-approved gates. Faster, but keeps prior run state;
  use only when you're confident the failed job will behave differently on a plain
  re-run (rarely the case for env-drift failures).

**Why a cancel is needed first.** CircleCI only reruns a workflow that is in a
terminal state. A run that still has a later gate `on_hold` (e.g. `hold_prod`
awaiting approval) stays `failing`/`on_hold` indefinitely and the rerun API
returns `400 Workflow must be in a terminal state to be rerun`. The script cancels
the run to force a terminal state before rerunning — this is safe: cancelling does
**not** roll back environments already deployed, it only stops pending gates.

Typical recovery flow for a deploy failure you've since fixed:

```bash
# fix the root cause (push the image / add the secret / grant the ECR policy) …
deploy.sh sat --repo Mercaso/<repo> --branch master --sha <sha> --rerun
```

Run it in the background like any other deploy; it walks the cascade to the target
on the fresh run and reports success or the next failure.

## Exit code reference

| Code | Meaning | What to tell the user |
|------|---------|------------------------|
| 0 | deploy succeeded — every stage through the target (or already success on a re-run) | Confirm deploy is live, link the workflow |
| 1 | usage / can't determine repo or slug | Run from inside the project git repo, or pass `--repo owner/repo` |
| 2 | missing CircleCI token | Run `circleci setup` or set `CIRCLECI_TOKEN` |
| 3 | no pipeline found for the SHA yet | CI hasn't ingested the commit; retry in a minute |
| 4 | no deploy job / workflow found | Branch may be filtered out, or no deploy job for the env |
| 5 | a build/test job failed | Enter the auto-fix loop above |
| 6 | a deploy job failed (stderr names which env in a cascade) | Fetch that deploy-job's logs; do not auto-retry |
| 7 | gate never reached on_hold within ~13 min | Check the pipeline manually |
| 8 | deploy job didn't finish within ~20 min | Check the workflow; job may be stuck |
| 9 | ambiguous detection | Re-run with explicit `--deploy-job`/`--approval-job`/`--workflow` |
| 10 | multiple deploy environments, none chosen | Ask the user which env, re-run with it |
| 11 | deploy job halted (no-op) — service not built in this pipeline | Not a real deploy; target the pipeline of the commit that changed the service, or `CI_DEPLOY_HALT_CHECK=0` to bypass |
| 12 | target commit authored by someone else (needs confirmation) | Show author + changed services; re-run with `--yes` once the user confirms |

## Requirements

- A CircleCI token with read+approve access to the project. The script reads
  `$CIRCLECI_TOKEN` first, then falls back to `~/.circleci/cli.yml`.
- `git`, `curl`, and `python3` on PATH.
- **Windows PowerShell:** use `scripts\deploy.ps1` or
  `scripts\fetch_failed_logs.ps1`. The wrappers require Git for Windows, or set
  `CI_DEPLOY_BASH` to a compatible `bash.exe`; they reuse the same arguments as
  the `.sh` scripts.
- **Local mode:** run from inside the project's git repository (the script needs
  `origin` and the current branch).
- **Remote mode (`--repo`):** an authenticated `gh` CLI (`gh auth status`). No
  local clone needed. Default GitHub org is `Mercaso`.
- A CircleCI workflow that deploys behind a manual-approval gate, with deploy jobs
  named with the environment embedded (`deploy_<env>`, `deploy-<env>`, …).
