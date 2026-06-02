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
RERUN_MODE=""          # "" | "from-start" | "from-failed"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         REPO_ARG="${2:-}"; shift 2 ;;
    --branch)       BRANCH_ARG="${2:-}"; shift 2 ;;
    --sha)          TARGET_SHA_ARG="${2:-}"; shift 2 ;;
    --workflow)     WORKFLOW_NAME="${2:-}"; shift 2 ;;
    --deploy-job)   DEPLOY_OVERRIDE="${2:-}"; shift 2 ;;
    --approval-job) APPROVAL_OVERRIDE="${2:-}"; shift 2 ;;
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
PIPELINE_ID=$(cc_get "https://circleci.com/api/v2/project/$PROJECT_SLUG/pipeline?branch=$BRANCH" \
  | TARGET_SHA="$TARGET_SHA" python3 -c "
import json, os, sys
target = os.environ['TARGET_SHA']
data = json.load(sys.stdin)
items = data.get('items', [])
# No target SHA (remote mode without --sha): take the latest pipeline on the
# branch — CircleCI returns items newest-first.
if not target:
    if items:
        print(items[0]['id'])
    sys.exit(0)
for p in items:
    if p.get('vcs', {}).get('revision', '') == target:
        print(p['id']); sys.exit(0)
" | tr -d '\r')
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

# Parse the chain: TARGET_ENV plus a STAGES array of "env<TAB>gate<TAB>deploy".
TARGET_ENV=""
STAGES=()
while IFS=$'\t' read -r KIND F1 F2 F3; do
  case "$KIND" in
    ENV)   TARGET_ENV="$F1" ;;
    STAGE) STAGES+=("$F1"$'\t'"$F2"$'\t'"$F3") ;;
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
    IFS=$'\t' read -r se _ _ <<<"$s"
    PLAN="${PLAN:+$PLAN → }$se"
  done
  echo "Cascade: $PLAN    (deploying $((${#STAGES[@]} - 1)) prerequisite env(s) before $TARGET_ENV)"
else
  IFS=$'\t' read -r se sg sd <<<"${STAGES[0]}"
  echo "Env: $se    deploy job: $sd    approval gate: ${sg:-(none)}"
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

# Poll the deploy job until terminal. 0 success, 6 failure, 8 timeout.
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
        echo "$DEPLOY_JOB succeeded for $SHORT_SHA ($ENV_NAME)."
        echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID"
        return 0 ;;
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

# ─── one stage: wait for tests, react to the gate, monitor the deploy ─────────
# Operates on the globals ENV_NAME / DEPLOY_JOB / APPROVAL_JOB (set per stage by
# the cascade loop). Returns: 0 done, 5 test failed, 6 deploy failed, 7 gate
# never held, 8 deploy timed out. Idempotent — a stage already deployed returns
# 0 on the first poll, so re-runs skip completed work.
run_stage() {
  local i APPROVAL_REQUEST_ID=""
  for ((i=1; i<=MAX_POLLS; i++)); do
    read -r TEST_FAIL HOLD_STATUS HOLD_APPROVAL_ID DEPLOY_STATUS \
      <<<"$(cc_get "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/job" | poll_status | tr -d '\r')"

    echo "[poll $i] tests=${TEST_FAIL} ${APPROVAL_JOB:-(no gate)}=$HOLD_STATUS $DEPLOY_JOB=$DEPLOY_STATUS"

    # Fail fast if any build/test job failed.
    if [[ "$TEST_FAIL" != "-" ]]; then
      echo "error: a build/test job ended with status '$TEST_FAIL' — not approving deploy." >&2
      echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
      return 5
    fi

    # Already past the gate (re-run / already-deployed prerequisite).
    case "$DEPLOY_STATUS" in
      success)
        echo "$DEPLOY_JOB already success — skipping ($ENV_NAME)."
        return 0 ;;
      failed|canceled|unauthorized|infrastructure_fail|timedout|errored)
        echo "error: $DEPLOY_JOB is in terminal failure state '$DEPLOY_STATUS'." >&2
        echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
        return 6 ;;
      running|queued)
        echo "$DEPLOY_JOB is already $DEPLOY_STATUS — skipping approval and monitoring."
        monitor_deploy; return $? ;;
    esac
    case "$HOLD_STATUS" in
      success)
        echo "$APPROVAL_JOB was already approved — monitoring deploy."
        monitor_deploy; return $? ;;
      on_hold)
        APPROVAL_REQUEST_ID="$HOLD_APPROVAL_ID"
        break ;;
    esac

    if (( i < MAX_POLLS )); then sleep "$POLL_INTERVAL"; fi
  done

  if [[ -z "$APPROVAL_REQUEST_ID" || "$APPROVAL_REQUEST_ID" == "-" ]]; then
    echo "error: ${APPROVAL_JOB:-approval gate} never reached on_hold within ~13 min. Check the workflow manually." >&2
    echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID" >&2
    return 7
  fi

  echo "Approving $APPROVAL_JOB ($APPROVAL_REQUEST_ID)..."
  cc_post "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/approve/$APPROVAL_REQUEST_ID" > /dev/null
  echo "Approved. Watch deploy at: https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID"

  monitor_deploy
  return $?
}

# ─── cascade: walk every stage from the earliest prerequisite to the target ───
for s in "${STAGES[@]}"; do
  IFS=$'\t' read -r ENV_NAME APPROVAL_JOB DEPLOY_JOB <<<"$s"
  if [[ ${#STAGES[@]} -gt 1 ]]; then
    echo "── Stage: $ENV_NAME ($DEPLOY_JOB, gate ${APPROVAL_JOB:-none}) ──"
  fi

  set +e
  run_stage
  STAGE_RC=$?
  set -e

  case "$STAGE_RC" in
    0) : ;;  # stage done, advance to the next
    6) echo "error: deploy failed at env '$ENV_NAME' — cascade stopped before ${TARGET_ENV}." >&2
       exit 6 ;;
    *) exit "$STAGE_RC" ;;  # 5 / 7 / 8 already explained on stderr
  esac
done

echo "All stages succeeded through $TARGET_ENV for $SHORT_SHA."
echo "  https://app.circleci.com/pipelines/workflows/$WORKFLOW_ID"
exit 0
