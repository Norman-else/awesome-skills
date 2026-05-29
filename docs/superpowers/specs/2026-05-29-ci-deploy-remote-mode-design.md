# ci-deploy: remote (no-local-clone) deploy mode

Date: 2026-05-29
Status: approved, implementing

## Problem

`ci-deploy` currently only works from inside a cloned repo: it derives the
CircleCI project slug from `git remote get-url origin`, the branch from
`git rev-parse HEAD`, and the target commit from `origin/<branch>`. Users want
to deploy a repo they have **not** cloned — naming it in natural language — and
target **the latest commit on `master` that the current GitHub user authored**.

## Decisions (locked with user)

- **Approach A — agent-orchestrated, thin script change.** The script stays pure
  CircleCI mechanics; repo search, disambiguation, and commit lookup (all needing
  judgment / interaction) live in SKILL.md and are done by the agent via `gh`.
- **Repo identification:** natural-language description → `gh search repos` in the
  **default org `Mercaso`**. Unique strong match runs automatically (announced);
  multiple / uncertain → ask via AskUserQuestion; zero → ask user to refine. An
  explicit `owner/repo` skips the search.
- **Target commit:** latest commit on `master` whose **author** (not committer —
  committer changes under rebase/squash) is the current `gh` user.
- **Additive:** the existing local mode is unchanged.

## Script changes — `scripts/deploy.sh`

Two new flags:

- `--repo <owner/repo>` — when given, skip `git remote` parsing. Slug rules:
  - `owner/repo` (one slash) → `gh/owner/repo`
  - `vcs/owner/repo` (two slashes) → used as-is
- `--branch <name>` — override the branch. Local mode default stays `HEAD`;
  remote mode (`--repo` given) defaults to `master`.

SHA resolution:

- `--sha` wins.
- Else if `--repo` given (remote) and no `--sha`: leave SHA empty → pipeline
  lookup takes the **latest pipeline on the branch** (no revision match).
- Else (local): `origin/<branch>` tip, as today.

All `git` calls are gated to local mode so the script runs outside any repo.
Pipeline lookup handles an empty target SHA by taking `items[0]` (CircleCI
returns newest-first). **Exit codes are unchanged.**

## SKILL.md changes

New section **"Deploying a repo you haven't cloned"**:

1. Resolve repo: `gh search repos --owner Mercaso "<desc>" --limit 10 --json fullName,description`
   → unique strong match auto-use (announce); multiple → AskUserQuestion; none →
   ask to refine; explicit `owner/repo` skips search.
2. Resolve commit: `login=$(gh api user --jq .login)`;
   `gh api "repos/<owner>/<repo>/commits?sha=master&author=$login&per_page=1" --jq '.[0].sha'`.
   Empty → tell the user; offer "deploy master tip instead" or stop.
3. Deploy: background `deploy.sh <env> --repo Mercaso/<repo> --branch master --sha <sha>`.
4. Env disambiguation (exit 10) and other exit codes behave as today.

**Critical boundary — autofix loop disabled in remote mode.** The exit-5 auto-fix
loop commits & pushes fixes, which requires a local clone. With no clone, on
exit 5 the agent fetches logs (`fetch_failed_logs.sh`) and reports the failure;
it does **not** enter the commit/push loop. If the user wants to fix, the agent
says a local clone is needed first.

Requirements: add authenticated `gh` CLI; document default org `Mercaso`.

## Versioning

Bump `awesome-skills` across all three manifests `0.1.6 → 0.1.7`.

## Out of scope

- Non-GitHub remotes in remote mode (Bitbucket) — `gh` is GitHub-only; local mode
  still handles `bb/`.
- Author filtering in local mode (stays branch-tip).
