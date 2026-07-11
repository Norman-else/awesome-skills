#!/usr/bin/env bash
# ci-deploy — approve a CircleCI manual-approval gate and watch the deploy job.
#
# Project-agnostic: detects the CircleCI project, workflow, and the
# approval/deploy/test jobs from the current git repo (local mode) or from
# explicit flags (remote mode), plus the CircleCI API. No per-repo config file.
#
# Usage:
#   deploy.sh [<env>] [options]
#
#   <env>                  Target environment (e.g. dev, sat, staging, prod).
#                          If omitted and the workflow has exactly one deploy
#                          environment, it is used. If multiple exist, the
#                          script exits 10 and prints the list so the caller
#                          can ask the user which one.
#
# Options:
#   --repo <owner/repo>    Remote mode — deploy a repo you have NOT cloned.
#                          Skips git; slug becomes gh/owner/repo (or pass a full
#                          vcs/owner/repo). Branch defaults to master; pair with
#                          --sha to target a specific commit.
#   --branch <name>        Override the branch (local default: current HEAD;
#                          remote default: master).
#   --sha <sha>            Deploy a specific commit (local default: branch's
#                          remote tip; remote default: latest pipeline on branch).
#   --workflow <name-or-id>  Pin the workflow when a pipeline has several.
#   --deploy-job <name>    Explicit deploy job (used when detection is ambiguous).
#   --approval-job <name>  Explicit approval gate job.
#   --service <name>       Monorepo mode — deploy ONE service. Resolves the deploy
#                          job (deploy_<svc>_<env>), gate (hold_<svc>_<env>) and,
#                          unless --sha is given, the latest commit that changed the
#                          service's path. Per-repo overrides: .claude/ci-deploy.json.
#   --service-path <glob>  Override the service's source path (default services/<svc>).
#   --test-job <name>      Restrict the "build failed" check to this one job.
#   --rerun                Rerun the matched workflow from the START before
#                          watching. Cancels the current run first (CircleCI only
#                          reruns terminal workflows), then watches the fresh run.
#                          Use to retry a deploy that failed on stale/cached state.
#   --rerun-from-failed    Rerun only the failed jobs + downstream (reuses upstream
#                          successes and approved gates). Faster; use when the fix
#                          is external (env/secret) and the job just needs rerunning.
#   --no-autofix           Accepted for parity; the auto-fix loop lives in the
#                          agent, not this script.
#
# Behaviour mirrors the original deploy-dev flow: resolve SHA -> find pipeline
# -> find workflow -> wait for tests -> approve the gate -> monitor the deploy.
set -euo pipefail

POLL_INTERVAL=20
MAX_POLLS=40           # ~13 min ceiling for tests + approval
MAX_DEPLOY_POLLS=60    # ~20 min ceiling for the deploy job itself

# ─── arg parsing ────────────────────────────────────────────────────────────
ENV_NAME=""
TARGET_SHA_ARG=""
WORKFLOW_NAME=""
DEPLOY_OVERRIDE=""
APPROVAL_OVERRIDE=""
TEST_OVERRIDE=""
REPO_ARG=""
BRANCH_ARG=""
SERVICE_ARG=""
SERVICE_PATH_ARG=""
RERUN_MODE=""          # "" | "from-start" | "from-failed"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         REPO_ARG="${2:-}"; shift 2 ;;
    --branch)       BRANCH_ARG="${2:-}"; shift 2 ;;
    --sha)          TARGET_SHA_ARG="${2:-}"; shift 2 ;;
    --workflow)     WORKFLOW_NAME="${2:-}"; shift 2 ;;
    --deploy-job)   DEPLOY_OVERRIDE="${2:-}"; shift 2 ;;
    --approval-job) APPROVAL_OVERRIDE="${2:-}"; shift 2 ;;
    --service)      SERVICE_ARG="${2:-}"; shift 2 ;;
    --service-path) SERVICE_PATH_ARG="${2:-}"; shift 2 ;;
    --test-job)     TEST_OVERRIDE="${2:-}"; shift 2 ;;
    --rerun)             RERUN_MODE="from-start"; shift ;;
    --rerun-from-failed) RERUN_MODE="from-failed"; shift ;;
    --no-autofix)   shift ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    -*)             echo "error: unknown flag: $1" >&2; exit 1 ;;
    *)              if [[ -z "$ENV_NAME" ]]; then ENV_NAME="$1"; else echo "error: unexpected arg: $1" >&2; exit 1; fi; shift ;;
  esac
done

# ─── token ──────────────────────────────────────────────────────────────────
if [[ -n "${CIRCLECI_TOKEN:-}" ]]; then
  CC_TOKEN="$(printf '%s' "$CIRCLECI_TOKEN" | tr -d '\r')"
elif [[ -f "$HOME/.circleci/cli.yml" ]]; then
  CC_TOKEN=$(awk '/^token:/ {print $2}' "$HOME/.circleci/cli.yml" | tr -d '\r' || true)
fi
if [[ -z "${CC_TOKEN:-}" ]]; then
  echo "error: no CircleCI token found. Set CIRCLECI_TOKEN or run 'circleci setup'." >&2
  exit 2
fi

cc_get()  { curl -sS --fail-with-body -H "Circle-Token: $CC_TOKEN" "$@"; }
cc_post() { curl -sS --fail-with-body -X POST -H "Circle-Token: $CC_TOKEN" "$@"; }

# ─── project slug ─────────────────────────────────────────────────────────────
# Remote mode (--repo): derive the slug from the flag, no git needed.
# Local mode: parse it from the origin remote, as before.
if [[ -n "$REPO_ARG" ]]; then
  case "$REPO_ARG" in
    */*/*) PROJECT_SLUG="$REPO_ARG" ;;        # already vcs/owner/repo
    */*)   PROJECT_SLUG="gh/$REPO_ARG" ;;      # owner/repo → assume GitHub
    *)     echo "error: --repo must be owner/repo or vcs/owner/repo (got '$REPO_ARG')." >&2; exit 1 ;;
  esac
else
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
  if [[ -z "$REMOTE_URL" ]]; then
    echo "error: no 'origin' remote found — run from inside the repo, or pass --repo owner/repo." >&2
    exit 1
  fi
  read -r VCS_PREFIX V1_PREFIX OWNER_REPO <<<"$(REMOTE_URL="$REMOTE_URL" python3 -c "
import os, re, sys
url = os.environ['REMOTE_URL'].strip()
m = re.search(r'(?:@|//)([^/:]+)[/:]([^/]+/[^/]+?)(?:\.git)?/?\$', url)
if not m:
    sys.exit(0)
host, owner_repo = m.group(1), m.group(2)
if 'bitbucket' in host:
    print('bb', 'bitbucket', owner_repo)
else:
    print('gh', 'github', owner_repo)
" | tr -d '\r')"
  if [[ -z "${OWNER_REPO:-}" ]]; then
    echo "error: could not parse a GitHub/Bitbucket project from origin remote ('$REMOTE_URL')." >&2
    exit 1
  fi
  PROJECT_SLUG="$VCS_PREFIX/$OWNER_REPO"
fi
echo "Project: $PROJECT_SLUG"

# ─── branch + target SHA ──────────────────────────────────────────────────────
# Branch: explicit flag wins; remote mode defaults to master; local mode reads HEAD.
if [[ -n "$BRANCH_ARG" ]]; then
  BRANCH="$BRANCH_ARG"
elif [[ -n "$REPO_ARG" ]]; then
  BRANCH="master"
else
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\r' || echo HEAD)
fi

# ─── monorepo service mode ────────────────────────────────────────────────────
# `--service X` deploys one service inside a monorepo: it maps the service to its
# source path and its deploy/approval job names (from an optional repo config file,
# or by convention), and — unless --sha is given — targets the pipeline of the
# latest commit on the branch that changed that path. This picks the path-filtered
# pipeline that actually BUILT the service, instead of the branch tip (whose deploy
# job for a non-modified service would halt into a no-op, now caught as exit 11).
if [[ -n "$SERVICE_ARG" ]]; then
  if [[ -z "$ENV_NAME" ]]; then
    echo "error: --service requires an environment, e.g. 'deploy.sh sat --service $SERVICE_ARG'." >&2
    exit 1
  fi
  # Optional per-repo config: .claude/ci-deploy.json (local: working tree; remote:
  # fetched via gh). Templates use {service} and {env}.
  CFG_JSON=""
  if [[ -n "$REPO_ARG" ]]; then
    CFG_JSON=$(gh api "repos/${PROJECT_SLUG#*/}/contents/.claude/ci-deploy.json?ref=$BRANCH" \
                 --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
  else
    _root=$(git rev-parse --show-toplevel 2>/dev/null || echo .)
    [[ -f "$_root/.claude/ci-deploy.json" ]] && CFG_JSON=$(cat "$_root/.claude/ci-deploy.json")
  fi
  read -r SVC_PATH DEPLOY_TMPL APPROVAL_TMPL < <(
    SERVICE="$SERVICE_ARG" ENV_NAME="$ENV_NAME" CFG_JSON="$CFG_JSON" \
    SERVICE_PATH_ARG="$SERVICE_PATH_ARG" python3 -c "
import json, os
svc = os.environ['SERVICE']; env = os.environ['ENV_NAME']
raw = os.environ.get('CFG_JSON', '').strip()
cfg = {}
if raw:
    try: cfg = json.loads(raw)
    except Exception: cfg = {}
def tmpl(v, d): return (v or d).replace('{service}', svc).replace('{env}', env)
path = os.environ.get('SERVICE_PATH_ARG') or tmpl(cfg.get('service_path'), 'services/{service}')
print(path, tmpl(cfg.get('deploy_job'), 'deploy_{service}_{env}'), tmpl(cfg.get('approval_job'), 'hold_{service}_{env}'))
")
  [[ -z "$DEPLOY_OVERRIDE" ]]   && DEPLOY_OVERRIDE="$DEPLOY_TMPL"
  [[ -z "$APPROVAL_OVERRIDE" ]] && APPROVAL_OVERRIDE="$APPROVAL_TMPL"
  echo "Service: $SERVICE_ARG    path: $SVC_PATH    deploy: $DEPLOY_OVERRIDE    gate: $APPROVAL_OVERRIDE"
  # Target the latest commit on the branch that changed the service's path.
  if [[ -z "$TARGET_SHA_ARG" ]]; then
    if [[ -n "$REPO_ARG" ]]; then
      TARGET_SHA_ARG=$(gh api "repos/${PROJECT_SLUG#*/}/commits?sha=$BRANCH&path=$SVC_PATH&per_page=1" \
                        --jq '.[0].sha' 2>/dev/null | tr -d '\r' || true)
    else
      git fetch origin "$BRANCH" --quiet 2>/dev/null || true
      TARGET_SHA_ARG=$(git log -n1 --format=%H "origin/$BRANCH" -- "$SVC_PATH" 2>/dev/null \
                        || git log -n1 --format=%H "$BRANCH" -- "$SVC_PATH" 2>/dev/null || true)
      TARGET_SHA_ARG="$(printf '%s' "$TARGET_SHA_ARG" | tr -d '\r')"
    fi
    if [[ -z "$TARGET_SHA_ARG" ]]; then
      echo "error: no commit on '$BRANCH' changed '$SVC_PATH' — can't find a pipeline that built $SERVICE_ARG." >&2
      echo "  Check the path (--service-path) or pass --sha explicitly." >&2
      exit 3
    fi
    echo "Resolved $SERVICE_ARG -> latest change ${TARGET_SHA_ARG:0:7} on $BRANCH (path: $SVC_PATH)."
  fi
fi

# Target SHA: explicit flag wins. In remote mode without --sha we leave it empty
# and let the pipeline lookup take the latest pipeline on the branch. In local
# mode without --sha we resolve the branch's remote tip via git.
if [[ -n "$TARGET_SHA_ARG" ]]; then
  TARGET_SHA="$TARGET_SHA_ARG"
elif [[ -n "$REPO_ARG" ]]; then
  TARGET_SHA=""
else
  git fetch origin "$BRANCH" --quiet 2>/dev/null || true
  TARGET_SHA=$(git rev-parse "origin/$BRANCH" 2>/dev/null || git rev-parse HEAD)
  TARGET_SHA="$(printf '%s' "$TARGET_SHA" | tr -d '\r')"
fi

if [[ -n "$TARGET_SHA" ]]; then
  SHORT_SHA="${TARGET_SHA:0:7}"
else
  SHORT_SHA="latest on $BRANCH"
fi
echo "Branch: $BRANCH    Target commit: $SHORT_SHA"

# ─── find pipeline for SHA ────────────────────────────────────────────────────
# Resolve a short/abbreviated --sha to the full 40-char revision when a local
# clone is present (CircleCI stores the full revision, so a bare short SHA never
# matches by equality). Remote mode has no clone; the prefix match below covers it.
if [[ -n "$TARGET_SHA" && -z "$REPO_ARG" ]]; then
  _full_sha=$(git rev-parse "$TARGET_SHA" 2>/dev/null | tr -d '\r' || true)
  [[ -n "$_full_sha" ]] && TARGET_SHA="$_full_sha"
fi

# CircleCI returns pipelines newest-first, ~20 per page. Walk pages until the
# pipeline whose revision matches the target (exact OR prefix, so short SHAs
# resolve) is found, or the history is exhausted (cap ~15 pages ≈ 300 pipelines).
# Without a target SHA we take the newest pipeline on the branch.
PIPELINE_ID=""
_page_token=""
for _pg in $(seq 1 15); do
  _pipe_url="https://circleci.com/api/v2/project/$PROJECT_SLUG/pipeline?branch=$BRANCH"
  [[ -n "$_page_token" ]] && _pipe_url="${_pipe_url}&page-token=${_page_token}"
  read -r PIPELINE_ID _page_token < <(cc_get "$_pipe_url" \
    | TARGET_SHA="$TARGET_SHA" python3 -c "
import json, os, sys
target = os.environ['TARGET_SHA']
data = json.load(sys.stdin)
items = data.get('items', [])
nxt = data.get('next_page_token') or '-'
if not target:
    print((items[0]['id'] if items else '-'), '-'); sys.exit(0)
for p in items:
    rev = p.get('vcs', {}).get('revision', '') or ''
    if rev == target or rev.startswith(target):
        print(p['id'], '-'); sys.exit(0)
print('-', nxt)
" | tr -d '\r')
  [[ "$PIPELINE_ID" == "-" ]] && PIPELINE_ID=""
  [[ "$_page_token" == "-" ]] && _page_token=""
  [[ -n "$PIPELINE_ID" ]] && break
  [[ -z "$TARGET_SHA" ]] && break      # no-SHA case already resolved on page 1
  [[ -z "$_page_token" ]] && break     # no more pages
done
if [[ -z "$PIPELINE_ID" ]]; then
  echo "error: no CircleCI pipeline found for $SHORT_SHA on '$BRANCH'." >&2
  echo "Hint: CI may not have picked up the commit yet. Try again in a minute, or check" >&2
  echo "  https://app.circleci.com/pipelines/$PROJECT_SLUG?branch=$BRANCH" >&2
  exit 3
fi
echo "Pipeline: $PIPELINE_ID"

# ─── choose the workflow (the one that contains a deploy job) ─────────────────
# A pipeline usually has one workflow. When there are several, we pick the one
# that contains a deploy-shaped job. If more than one qualifies, we bail to the
# caller (exit 9) so they can pin it with --workflow.
HAS_DEPLOY_PY='import json, re, sys
kw = re.compile(r"(?:^|[-_])(?:deploy|release|ship|publish)(?:$|[-_])", re.I)
d = json.load(sys.stdin)
sys.exit(0 if any(kw.search(j.get("name","")) for j in d.get("items", [])) else 1)'

CANDIDATE_IDS=()
while read -r WID; do
  [[ -z "$WID" ]] && continue
  WJOBS=$(cc_get "https://circleci.com/api/v2/workflow/$WID/job")
  if printf '%s' "$WJOBS" | python3 -c "$HAS_DEPLOY_PY"; then
    CANDIDATE_IDS+=("$WID")
  fi
done < <(cc_get "https://circleci.com/api/v2/pipeline/$PIPELINE_ID/workflow" \
  | WF_NAME="$WORKFLOW_NAME" python3 -c "
import json, os, sys
want = os.environ.get('WF_NAME', '')
data = json.load(sys.stdin)
items = data.get('items', [])
if want:
    items = [w for w in items if w.get('name') == want or w.get('id') == want]
# A rerun supersedes earlier runs of the same workflow name; CircleCI marks the
# superseded run 'canceled'. Drop those so a re-run pipeline is not mistaken for
# several distinct deploy workflows (which would trip the exit-9 ambiguity check).
items = [w for w in items if w.get('status') != 'canceled']
# Collapse to one run per workflow name: prefer a still-active run, then the most
# recently created. Genuinely distinct workflows (different names) stay separate
# candidates, so real multi-workflow ambiguity still surfaces as exit 9.
active = {'running', 'on_hold', 'not_run', 'needs_setup'}
items.sort(key=lambda w: (w.get('status') in active, w.get('created_at', '')), reverse=True)
seen = set()
for w in items:
    name = w.get('name', '')
    if name in seen:
        continue
    seen.add(name)
    print(w['id'])
" | tr -d '\r')

if [[ ${#CANDIDATE_IDS[@]} -eq 0 ]]; then
  echo "error: no workflow with a deploy job found in pipeline $PIPELINE_ID." >&2
  [[ -n "$WORKFLOW_NAME" ]] && echo "  (filtered to --workflow '$WORKFLOW_NAME')" >&2
  exit 4
fi
if [[ ${#CANDIDATE_IDS[@]} -gt 1 ]]; then
  echo "error: multiple workflows contain deploy jobs — re-run with --workflow <name>." >&2
  exit 9
fi
WORKFLOW_ID="${CANDIDATE_IDS[0]}"
echo "Workflow: $WORKFLOW_ID"

# ─── optional: rerun the workflow before watching (--rerun / --rerun-from-failed) ─
# CircleCI only reruns a workflow that is in a TERMINAL state. A live run that is
# still on_hold (e.g. a later prod gate awaiting approval) never terminates on its
# own, so we cancel it first to force a terminal state, then trigger the rerun and
# switch to watching the NEW run that comes back.
#   --rerun             → rerun from the start (fresh build; gates re-open, so a
#                         prior deploy failure caused by stale/cached state clears).
#   --rerun-from-failed → rerun only the failed jobs and their downstream, reusing
#                         upstream successes and already-approved gates (faster, but
#                         keeps prior run state — use when the fix is purely external,
#                         e.g. an env/secret change, and the failed job just needs
#                         to run again).
# After the rerun, $WORKFLOW_ID points at the new run and the normal detect →
# cascade → watch flow below proceeds against it unchanged.
if [[ -n "$RERUN_MODE" ]]; then
  echo "Rerun requested ($RERUN_MODE) — canceling $WORKFLOW_ID to reach a terminal state..."
  cc_post "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/cancel" > /dev/null 2>&1 || true
  for ((k=1; k<=15; k++)); do
    WSTAT=$(cc_get "https://circleci.com/api/v2/workflow/$WORKFLOW_ID" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" | tr -d '\r')
    case "$WSTAT" in canceled|failed|success|error) break ;; esac
    sleep 4
  done
  RERUN_BODY='{}'
  [[ "$RERUN_MODE" == "from-failed" ]] && RERUN_BODY='{"from_failed": true}'
  NEW_WF=$(cc_post -H "Content-Type: application/json" -d "$RERUN_BODY" \
    "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/rerun" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('workflow_id',''))" | tr -d '\r')
  if [[ -z "$NEW_WF" ]]; then
    echo "error: rerun did not return a new workflow id (was the old run terminal?)." >&2
    exit 9
  fi
  WORKFLOW_ID="$NEW_WF"
  echo "Rerun started. New workflow: $WORKFLOW_ID"
  echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID"
  # The new run's jobs may take a moment to materialize; wait until they appear so
  # detect.py can resolve the chain from a populated job list.
  for ((k=1; k<=15; k++)); do
    NJOBS=$(cc_get "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/job" \
      | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null | tr -d '\r')
    [[ "${NJOBS:-0}" -gt 0 ]] && break
    sleep 3
  done
fi

WF_JOBS_JSON=$(cc_get "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/job")

# ─── resolve the deploy chain (cascade) ───────────────────────────────────────
# detect.py (EMIT_CHAIN=1) derives the ordered prerequisite chain from the job
# dependency graph. It exits 9 (ambiguous job match) or 10 (multiple envs, none
# chosen) for the caller to resolve. On success it prints:
#   ENV\t<target_env>
#   STAGE\t<env>\t<approval_job>\t<deploy_job>   (earliest first, target last)
# A single-environment workflow yields exactly one STAGE line, so this is a
# strict superset of the old single-env behaviour.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set +e
DETECT_OUT=$(printf '%s' "$WF_JOBS_JSON" | \
  ENV_NAME="$ENV_NAME" DEPLOY_OVERRIDE="$DEPLOY_OVERRIDE" APPROVAL_OVERRIDE="$APPROVAL_OVERRIDE" \
  EMIT_CHAIN=1 python3 "$SCRIPT_DIR/detect.py" | tr -d '\r')
DETECT_RC=$?
set -e

case "$DETECT_RC" in
  0) : ;;
  9)  echo "$DETECT_OUT" >&2; exit 9 ;;
  10) echo "$DETECT_OUT" >&2; exit 10 ;;
  *)  echo "$DETECT_OUT" >&2; exit "${DETECT_RC:-4}" ;;
esac

# Split an "env<TAB>gates<TAB>deploy" tuple into STAGE_ENV / STAGE_GATES /
# STAGE_DEPLOY, PRESERVING an empty gates field. `IFS=$'\t' read` can't do this:
# TAB is an IFS *whitespace* char, so read collapses a missing middle field (a
# stage with no approval gate — e.g. an auto-deploy dev) and shifts the deploy-job
# name into gates, leaving the deploy job blank, which then hangs the stage on an
# empty job name. Manual prefix/suffix stripping keeps empty fields intact.
split_stage() {
  local t="$1"
  STAGE_ENV="${t%%$'\t'*}";   t="${t#*$'\t'}"
  STAGE_GATES="${t%%$'\t'*}"
  STAGE_DEPLOY="${t#*$'\t'}"
}

# Parse the chain: TARGET_ENV plus a STAGES array of "env<TAB>gates<TAB>deploy".
# Read raw lines and peel off KIND by hand (same TAB-is-whitespace reason as
# split_stage) so a stage's empty gates field survives into the array.
TARGET_ENV=""
STAGES=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  KIND="${line%%$'\t'*}"
  REST="${line#*$'\t'}"
  case "$KIND" in
    ENV)   TARGET_ENV="$REST" ;;
    STAGE) STAGES+=("$REST") ;;   # "env<TAB>gates<TAB>deploy", empty gates kept
  esac
done <<<"$DETECT_OUT"

if [[ ${#STAGES[@]} -eq 0 ]]; then
  echo "error: could not resolve any deploy stage for env '${ENV_NAME:-?}'." >&2
  exit 4
fi

# Announce the plan. With prerequisites this is the "deploy dev → sat → prod"
# cascade the caller relays to the user.
if [[ ${#STAGES[@]} -gt 1 ]]; then
  PLAN=""
  for s in "${STAGES[@]}"; do
    split_stage "$s"
    PLAN="${PLAN:+$PLAN → }$STAGE_ENV"
  done
  echo "Cascade: $PLAN    (deploying $((${#STAGES[@]} - 1)) prerequisite env(s) before $TARGET_ENV)"
else
  split_stage "${STAGES[0]}"
  echo "Env: $STAGE_ENV    deploy job: $STAGE_DEPLOY    approval gate(s): ${STAGE_GATES:-(none)}"
fi

# ─── per-poll status extractor ────────────────────────────────────────────────
# Prints: <test_fail_status_or_dash>\t<hold_status>\t<hold_approval_id>\t<deploy_status>
# The build/test-failure scan skips ALL deploy-shaped jobs (not just the current
# one) so a sibling stage's deploy can't be misread as a failed test.
poll_status() {
  DEPLOY_JOB="$DEPLOY_JOB" APPROVAL_JOB="$APPROVAL_JOB" TEST_JOB="$TEST_OVERRIDE" python3 -c "
import json, os, re, sys
KW = re.compile(r'(?:^|[-_])(?:deploy|release|ship|publish)(?:\$|[-_])', re.I)
data = json.load(sys.stdin)
deploy = os.environ['DEPLOY_JOB']
appr = os.environ.get('APPROVAL_JOB', '')
testjob = os.environ.get('TEST_JOB', '')
FAIL = {'failed', 'canceled', 'unauthorized'}
hold, hold_id, dep, test_fail = '-', '-', '-', '-'
for j in data.get('items', []):
    n, s, t = j.get('name'), j.get('status') or '-', j.get('type')
    if n == deploy:
        dep = s
    elif appr and n == appr:
        hold = s
        hold_id = j.get('approval_request_id') or j.get('id') or '-'
for j in data.get('items', []):
    n, s, t = j.get('name'), j.get('status'), j.get('type')
    if t == 'approval' or KW.search(n or ''):
        continue
    if testjob and n != testjob:
        continue
    if s in FAIL:
        test_fail = s
        break
print('%s\t%s\t%s\t%s' % (test_fail, hold, hold_id, dep))
"
}

# ─── no-op / halt detection ─────────────────────────────────────────────
# A CircleCI job that runs `circleci-agent step halt` finishes as *success* while
# doing nothing. This is common in path-filtered monorepos: a service's deploy job
# is present in every pipeline's matrix but halts (right after its precondition
# step) in any pipeline that did not build that service. Such a no-op is
# indistinguishable from a real deploy by status alone, but it runs only a couple
# of setup steps in a fraction of the time. deploy_looks_real() returns 0 (real)
# or 1 (looks halted). Tunables: CI_DEPLOY_HALT_CHECK=0 disables it entirely;
# CI_DEPLOY_HALT_MAX_STEPS (default 4) and CI_DEPLOY_HALT_MAX_MS (default 90000)
# set the thresholds.
deploy_looks_real() {
  [[ "${CI_DEPLOY_HALT_CHECK:-1}" == "0" ]] && return 0
  local num
  num=$(cc_get "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/job" \
    | DEPLOY_JOB="$DEPLOY_JOB" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
print(next((str(j.get('job_number','')) for j in d.get('items', []) if j.get('name') == os.environ['DEPLOY_JOB']), ''))
" | tr -d '\r')
  [[ -z "$num" ]] && return 0   # can't resolve the job number -> don't block
  cc_get "https://circleci.com/api/v1.1/project/$PROJECT_SLUG/$num" \
    | CI_DEPLOY_HALT_MAX_STEPS="${CI_DEPLOY_HALT_MAX_STEPS:-4}" \
      CI_DEPLOY_HALT_MAX_MS="${CI_DEPLOY_HALT_MAX_MS:-90000}" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
steps = d.get('steps') or []
ms = d.get('build_time_millis') or 0
maxst = int(os.environ['CI_DEPLOY_HALT_MAX_STEPS'])
maxms = int(os.environ['CI_DEPLOY_HALT_MAX_MS'])
# A real deploy runs checkout + actual deploy steps, well beyond setup+precondition.
# A halt truncates the job to only the early steps, quickly.
sys.exit(1 if (len(steps) <= maxst and ms < maxms) else 0)
"
}

# Poll the deploy job until terminal. 0 success, 6 failure, 8 timeout, 11 no-op halt.
monitor_deploy() {
  echo "Monitoring $DEPLOY_JOB..."
  local j status
  for ((j=1; j<=MAX_DEPLOY_POLLS; j++)); do
    status=$(cc_get "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/job" \
      | DEPLOY_JOB="$DEPLOY_JOB" python3 -c "
import json, os, sys
data = json.load(sys.stdin)
for jb in data.get('items', []):
    if jb.get('name') == os.environ['DEPLOY_JOB']:
        print(jb.get('status') or '-'); break
else:
    print('-')
" | tr -d '\r')
    echo "[deploy poll $j] $DEPLOY_JOB=$status"
    case "$status" in
      success)
        if deploy_looks_real; then
          echo "$DEPLOY_JOB succeeded for $SHORT_SHA ($ENV_NAME)."
          echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID"
          return 0
        fi
        echo "error: $DEPLOY_JOB reported 'success' but appears to have HALTED early (no-op)." >&2
        echo "  It ran only setup/precondition steps — nothing was actually deployed." >&2
        echo "  In a path-filtered monorepo this means the service was NOT built in this pipeline;" >&2
        echo "  target the pipeline of the commit that changed the service (git log -- <path>)," >&2
        echo "  or set CI_DEPLOY_HALT_CHECK=0 to bypass this check." >&2
        echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
        return 11 ;;
      failed|canceled|unauthorized|infrastructure_fail|timedout|terminated_unknown|errored|not_run)
        echo "error: $DEPLOY_JOB ended with status '$status'." >&2
        echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
        return 6 ;;
    esac
    if (( j < MAX_DEPLOY_POLLS )); then sleep "$POLL_INTERVAL"; fi
  done
  echo "error: $DEPLOY_JOB did not finish within ~20 min — check the pipeline manually." >&2
  echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
  return 8
}

# ─── one stage: clear every prerequisite gate, then monitor the deploy ────────
# Operates on the globals ENV_NAME / DEPLOY_JOB / GATES (an ordered array of the
# approval-gate job names this stage must clear, set per stage by the cascade
# loop). Returns: 0 done, 5 test failed, 6 deploy failed, 7 a gate never held,
# 8 deploy timed out.
#
# A stage may sit behind SEVERAL sequential gates (e.g. a build-approval that
# unblocks the build, then a deploy-approval that unblocks the deploy). Each gate
# only opens once the previous one is approved and its downstream job runs, so we
# approve them one at a time, waiting for each to reach on_hold first. Stages with
# one gate (the common case) or none (auto-deploy) are just the trivial cases of
# this loop. Idempotent — an already-approved gate is skipped and an already-
# deployed stage returns 0 on the first poll, so re-runs skip completed work.
run_stage() {
  local gate i APPROVAL_REQUEST_ID HOLD_STATUS
  for gate in "${GATES[@]}"; do
    [[ -z "$gate" ]] && continue        # empty field → stage has no gate
    APPROVAL_REQUEST_ID=""
    HOLD_STATUS=""
    for ((i=1; i<=MAX_POLLS; i++)); do
      read -r TEST_FAIL HOLD_STATUS HOLD_APPROVAL_ID DEPLOY_STATUS \
        <<<"$(cc_get "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/job" | APPROVAL_JOB="$gate" poll_status | tr -d '\r')"

      echo "[poll $i] tests=${TEST_FAIL} $gate=$HOLD_STATUS $DEPLOY_JOB=$DEPLOY_STATUS"

      # Fail fast if any build/test job failed.
      if [[ "$TEST_FAIL" != "-" ]]; then
        echo "error: a build/test job ended with status '$TEST_FAIL' — not approving deploy." >&2
        echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
        return 5
      fi

      # Deploy already terminal/running (re-run / already-deployed prerequisite).
      case "$DEPLOY_STATUS" in
        success)
          if deploy_looks_real; then
            echo "$DEPLOY_JOB already success — skipping ($ENV_NAME)."
            return 0
          fi
          echo "error: $DEPLOY_JOB is 'success' but appears to have HALTED early (no-op) — nothing deployed." >&2
          echo "  Target the pipeline where the service was actually built, or CI_DEPLOY_HALT_CHECK=0 to bypass." >&2
          echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
          return 11 ;;
        failed|canceled|unauthorized|infrastructure_fail|timedout|errored)
          echo "error: $DEPLOY_JOB is in terminal failure state '$DEPLOY_STATUS'." >&2
          echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
          return 6 ;;
        running|queued)
          echo "$DEPLOY_JOB is already $DEPLOY_STATUS — skipping remaining approvals and monitoring."
          monitor_deploy; return $? ;;
      esac

      case "$HOLD_STATUS" in
        success)
          echo "$gate already approved — moving on."
          break ;;
        on_hold)
          APPROVAL_REQUEST_ID="$HOLD_APPROVAL_ID"
          echo "Approving $gate ($APPROVAL_REQUEST_ID)..."
          cc_post "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/approve/$APPROVAL_REQUEST_ID" > /dev/null
          echo "Approved $gate."
          break ;;
      esac

      if (( i < MAX_POLLS )); then sleep "$POLL_INTERVAL"; fi
    done

    # The gate neither opened nor was already approved within the window.
    if [[ "$HOLD_STATUS" != "success" && ( -z "$APPROVAL_REQUEST_ID" || "$APPROVAL_REQUEST_ID" == "-" ) ]]; then
      echo "error: gate '$gate' never reached on_hold within ~13 min. Check the workflow manually." >&2
      echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
      return 7
    fi
  done

  # Every gate cleared (or the stage had none) — watch the deploy to completion.
  echo "Watch deploy at: https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID"
  monitor_deploy
  return $?
}

# ─── cascade: walk every stage from the earliest prerequisite to the target ───
for s in "${STAGES[@]}"; do
  split_stage "$s"
  ENV_NAME="$STAGE_ENV"
  GATES_CSV="$STAGE_GATES"
  DEPLOY_JOB="$STAGE_DEPLOY"
  IFS=',' read -ra GATES <<<"$GATES_CSV"   # ordered approval gates for this stage
  if [[ ${#STAGES[@]} -gt 1 ]]; then
    echo "── Stage: $ENV_NAME ($DEPLOY_JOB, gates: ${GATES_CSV:-none}) ──"
  fi

  set +e
  run_stage
  STAGE_RC=$?
  set -e

  case "$STAGE_RC" in
    0) : ;;  # stage done, advance to the next
    6) echo "error: deploy failed at env '$ENV_NAME' — cascade stopped before ${TARGET_ENV}." >&2
       exit 6 ;;
    11) echo "error: deploy at env '$ENV_NAME' halted (no-op) — nothing deployed; cascade stopped before ${TARGET_ENV}." >&2
        exit 11 ;;
    *) exit "$STAGE_RC" ;;  # 5 / 7 / 8 already explained on stderr
  esac
done

echo "All stages succeeded through $TARGET_ENV for $SHORT_SHA."
echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID"
exit 0
