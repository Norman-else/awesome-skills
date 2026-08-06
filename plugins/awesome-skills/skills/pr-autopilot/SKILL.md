---
name: pr-autopilot
description: >-
  After a PR already exists, drive it to merged-and-deployed on autopilot. Polls its
  CI checks and human review comments in a loop: fixes failing CI, applies the changes
  human reviewers ask for, pushes each round, waits for the required approval, then
  squash-merges into the base branch and deploys that branch to a chosen environment
  via the ci-deploy skill. Use WHENEVER the user wants an open PR watched, fixed,
  merged and shipped hands-off: "盯着这个PR处理完评论就合并然后部署到sat",
  "自动合并并部署accounting-service到sat", "auto-merge this PR and deploy to sat",
  "ship this PR once it's green", "merge and deploy when ready", or /pr-autopilot
  (Claude) or $pr-autopilot (Codex) with just an environment. Also trigger it right
  after you open a PR yourself and the user asked for the whole flow. Do NOT use for
  opening a PR (that is a plain gh/commit task) or for a standalone deploy with no PR
  to merge first (use ci-deploy directly).
---

# PR Autopilot: watch → fix → merge → deploy

Take an **existing** PR from "just opened" to "merged and deployed" without babysitting.
The user invoked this to get the change *out*, so treat CI failures and reviewer
comments as work to do, not stopping points — only pause on the explicit stop
conditions below.

**Works on both Codex and Claude Code.** It relies only on `gh` + `git` and the sibling
**ci-deploy** skill (shipped in this same pack). Where a step names a client-specific tool
(e.g. Claude's Monitor), a portable fallback is given right beside it.

## Inputs

- **PR** — the current branch's open PR. Resolve with `gh pr view --json number,url,headRefName,baseRefName`.
  If the current branch has no PR, stop and say so (this skill starts *after* a PR exists).
- **service** — **auto-detected from the PR's changed files; the user does NOT provide it.**
  The diff paths under `services/<name>/` name the service to deploy (see Phase C). In a
  monorepo the change itself tells you what to ship, so asking would be redundant.
- **environment** — the **only** input the user gives (`dev` / `sat` / `prod`). If they
  didn't name one, ask (or let ci-deploy resolve in Phase C) — never guess a deploy target.

The invocation carries at most the environment. Detect the service from the PR yourself;
keep both for Phase C. Phases A–B need neither.

## The loop (Phase A → B → C)

Announce the plan up front (one line: "watching PR #N, will fix CI + human comments,
wait for approval, squash-merge, then deploy `<service>` to `<env>`"), then run:

```
loop:
  read PR readiness  →  drive it toward CLEAN  →  re-read
when CLEAN:          →  squash-merge (Phase B)  →  deploy (Phase C)
```

### Reading readiness — one signal drives everything

GitHub already computes a single field that folds together checks, approval, conflicts,
and required conversation resolution: `mergeStateStatus`. Read it plus the pieces you
need to *act* on each state:

```bash
gh pr view <pr> --json number,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,headRefOid \
  --jq '{state: .mergeStateStatus, mergeable, review: .reviewDecision,
         failing: [.statusCheckRollup[] | select(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT" or .conclusion=="CANCELLED" or .state=="FAILURE" or .state=="ERROR") | (.name // .context)],
         pending: [.statusCheckRollup[] | select(.status=="QUEUED" or .status=="IN_PROGRESS" or .state=="PENDING") | (.name // .context)]}'
```

Act on `mergeStateStatus`:

| state | meaning | what to do |
|-------|---------|------------|
| `CLEAN` | mergeable, approved, checks green | → Phase B (merge) |
| `BLOCKED` | missing approval, OR failing required check, OR unresolved conversation | diagnose which (below) and act |
| `BEHIND` | base moved; branch must update first | update branch, push, re-poll |
| `DIRTY` | merge conflicts | resolve conflicts, push, re-poll |
| `UNSTABLE` | a non-required check is failing/pending | if it's a real required-for-you check, fix it; else treat like BLOCKED-on-approval |
| `UNKNOWN` | GitHub still computing | wait briefly, re-poll (don't act) |

`BLOCKED` is the interesting one — it means *something* you can advance. Look at the
readiness JSON: if `failing` is non-empty → **fix CI**. If checks are all green and
`reviewDecision != "APPROVED"` → the only thing left is human approval or an unresolved
human thread → **handle comments, then wait**.

### Fixing failing CI

The failing checks are CircleCI checks on this repo. Diagnose the **root cause, not the
symptom**, before touching code (on Claude, the `superpowers:systematic-debugging` skill
helps structure this).

1. Get the failing check's details/URL from `statusCheckRollup` (`detailsUrl`).
2. Pull the actual failed step output. Reuse ci-deploy's log fetcher — it ships in this
   same pack, in the ci-deploy skill's `scripts/` dir — passing the workflow id from the
   check URL:
   `<ci-deploy-skill-dir>/scripts/fetch_failed_logs.sh <workflow-id>`
   (locate the ci-deploy skill in the installed pack; or just open `detailsUrl`). Read the
   diagnostic, not 50k lines of build chatter.
3. Apply the **smallest** fix that addresses the root cause. Don't refactor, don't add
   features, don't silence the check with skips / `--no-verify` / `# type: ignore`
   unless the user explicitly asked.
4. Commit (`fix: <thing> caught by CI`) and push to the **PR's head branch**.
5. Re-poll. New checks will run against the new tip.

### Handling review comments — HUMANS ONLY

Only apply changes requested by **human** reviewers. Ignore every bot comment
(CodeRabbit, bugbot, cursor, etc.) and always ignore the literal `bugbot run` trigger.
Bots surface noise and their own retrigger commands; acting on them causes churn and
can fight the humans. The human comments are the ones that gate the merge.

Fetch unresolved review threads with their author type (GraphQL gives `isResolved` +
`author.__typename`, which is `Bot` for bot accounts):

```bash
owner_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh api graphql -f query='
  query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        reviewThreads(first:100){ nodes{
          id isResolved
          comments(first:1){ nodes{ author{ login __typename } body path } }
        }}}}}' \
  -f owner="${owner_repo%/*}" -f name="${owner_repo#*/}" -F pr=<pr> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | {id, author: .comments.nodes[0].author.login, type: .comments.nodes[0].author.__typename,
           path: .comments.nodes[0].path, body: .comments.nodes[0].body}'
```

For each unresolved thread, **keep it only if** `type == "User"` AND the body is not a
bot trigger (`bugbot run` and similar). Also check top-level issue comments and the
review summaries (`gh pr view <pr> --json reviews,comments`) for human change-requests
that aren't inline threads.

For each qualifying human comment:
1. Make the requested code change (smallest change that satisfies the ask; if the ask is
   genuinely a judgment call or you disagree on technical grounds, that's a stop
   condition — see below — don't silently comply or silently ignore).
2. After pushing the fix, reply to the thread summarizing what you did and resolve it:
   ```bash
   # reply on an inline review thread (via its first comment id) or issue comment,
   # then resolve the thread so "require conversation resolution" stops blocking:
   gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<threadId>
   ```
3. Batch the round: apply all qualifying fixes, then ONE commit + push, then reply/resolve
   each thread. Re-poll.

### Waiting on human approval (nothing left for you to do)

When checks are green, conflicts are clear, all human threads are resolved, and the only
gap is `reviewDecision != "APPROVED"` — the answer chosen for this skill is **wait for a
human to approve**. Do not `--admin` merge, do not enable `--auto` and walk away; keep the
loop alive and re-poll until a human approves.

Because there's nothing to fix while waiting, poll *slowly* so you don't spin — re-check
every few minutes rather than busy-looping (on Claude, the Monitor tool can wait on the
condition `gh pr view <pr> --json reviewDecision --jq .reviewDecision` returning
`APPROVED`). Give the user one line when you start waiting ("all green, resolved N
comments — waiting on human approval") and one line when approval lands. Don't narrate
every poll.

## Phase B: Squash and Merge

Once `mergeStateStatus == CLEAN`, merge with squash:

```bash
gh pr merge <pr> --squash
```

Confirm it merged (`gh pr view <pr> --json state,mergeCommit --jq '{state, sha: .mergeCommit.oid}'`
→ `MERGED`). This is the point of no return; only reach it when the state was genuinely
CLEAN. Report the squash-merge commit SHA on the base branch — that's what deploys next.

## Phase C: Deploy the merged base branch

Now the change is on the base branch (usually `master`). Deploy it via the **ci-deploy**
skill (shipped in this same pack) — do NOT hand-roll CircleCI approvals; invoke the skill
so its cascade / gate logic and auto-fix loop are reused.

1. **Detect the repo** — `gh repo view --json nameWithOwner`.
2. **Auto-detect the service from the PR** (the user didn't provide it). The changed
   files under `services/<name>/` are what this PR ships:
   ```bash
   gh pr view <pr> --json files \
     --jq '[.files[].path | select(startswith("services/")) | split("/")[1]] | unique | .[]'
   ```
   - **Exactly one** service → that's it; deploy monorepo-style with `--service <svc>`.
   - **Multiple** services changed → ask the user which to deploy (ci-deploy ships one
     service per run; offer to deploy each in turn).
   - **None** (no `services/` paths) → not a monorepo service; deploy without `--service`.

   Detect this once (you already read the PR in Phase A) and reuse it; `gh pr view --json
   files` still works after the merge.
3. **Invoke the ci-deploy skill** for the base branch (its default target is the branch
   tip, which is now your squash-merge commit). Invoke it the way your client runs skills —
   `$ci-deploy` on Codex, the ci-deploy skill (`/ci-deploy`) on Claude — passing:
   - Monorepo: `<env> --service <service>`.
   - Single service: `<env>`.
   - No environment given: pass none and let ci-deploy resolve or ask (it exits 10 / asks
     when several environments exist).

   ci-deploy runs its deploy in the background and reports success or the failure to fix;
   relay its result to the user.

Make sure you are on / targeting the **base branch** for the deploy, not the now-merged
feature branch. ci-deploy targets the current branch's tip by default, so `git checkout
<base> && git pull` first (or pass the merge SHA), otherwise you'd deploy a stale tip.

## Stop conditions — pause and ask the user

Keep going through CI fixes and human comments autonomously, but STOP and ask when:

- **A reviewer's request is a judgment/product call**, or you technically disagree with it
  (e.g. they assert an API shape you believe is wrong). Don't silently comply or ignore —
  surface it and reason about it honestly before you comply or push back (on Claude, the
  `superpowers:receiving-code-review` skill helps).
- **CI fix loop hits 5 iterations**, or the **same root cause fails twice in a row**, or
  the failure is **infrastructure/flaky** (network blip, runner OOM 137, checkout failure)
  — that's not a code fix. Offer a retry, don't patch.
- **Merge conflict is non-trivial** — semantic conflicts you can't resolve confidently
  without changing behavior.
- **The PR gets new commits you didn't push** (someone else is working on it) — re-sync and
  confirm before continuing.
- **ci-deploy returns a deploy failure** (exit 6) — env drift needs eyes; don't auto-retry.

## Notes

- Everything runs on the **PR's head branch** until merge, then the **base branch** for
  deploy. Never force-push; use plain pushes so reviewers' local state stays sane.
- One tight update per round (what you fixed, what you pushed, new state) — not a poll log.
- This skill orchestrates; it delegates deployment to the ci-deploy skill and CI diagnosis
  to normal root-cause debugging rather than re-implementing either.
