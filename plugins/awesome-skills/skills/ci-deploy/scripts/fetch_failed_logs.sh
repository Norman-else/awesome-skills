#!/usr/bin/env bash
# Fetch the failed-step output for CircleCI job(s) inside a workflow.
#
# Usage:
#   fetch_failed_logs.sh <workflow-id> [job-name]
#
# If job-name is omitted, every job in the workflow whose status is "failed" is
# inspected. The project slug (github/OWNER/REPO for the v1.1 API) is derived
# from the current git repo's origin remote. For each failed job it walks the
# v1.1 job detail, finds steps whose actions failed (or exited non-zero),
# fetches each step's signed output_url, decompresses if gzipped, and prints the
# tail (last ~300 lines per step) so the reader sees the diagnostic without
# drowning in 50k lines of resolver chatter.
#
# Override the tail length with TAIL_LINES=N.
set -euo pipefail

WORKFLOW_ID="${1:-}"
JOB_NAME="${2:-}"
TAIL_LINES="${TAIL_LINES:-300}"

if [[ -z "$WORKFLOW_ID" ]]; then
  echo "usage: $0 <workflow-id> [job-name]" >&2
  exit 1
fi

# ─── token ────────────────────────────────────────────────────────────────────
if [[ -n "${CIRCLECI_TOKEN:-}" ]]; then
  CC_TOKEN="$(printf '%s' "$CIRCLECI_TOKEN" | tr -d '\r')"
elif [[ -f "$HOME/.circleci/cli.yml" ]]; then
  CC_TOKEN=$(awk '/^token:/ {print $2}' "$HOME/.circleci/cli.yml" | tr -d '\r' || true)
fi
if [[ -z "${CC_TOKEN:-}" ]]; then
  echo "error: no CircleCI token found. Set CIRCLECI_TOKEN or run 'circleci setup'." >&2
  exit 2
fi

# ─── project slug (v1.1 form: github/OWNER/REPO) from git remote ──────────────
REMOTE_URL=$(git remote get-url origin 2>/dev/null | tr -d '\r' || true)
PROJECT_V1=$(REMOTE_URL="$REMOTE_URL" python3 -c "
import os, re, sys
url = os.environ.get('REMOTE_URL', '').strip()
m = re.search(r'(?:@|//)([^/:]+)[/:]([^/]+/[^/]+?)(?:\.git)?/?\$', url)
if not m:
    sys.exit(0)
host, owner_repo = m.group(1), m.group(2)
print(('bitbucket/' if 'bitbucket' in host else 'github/') + owner_repo)
" | tr -d '\r')
if [[ -z "$PROJECT_V1" ]]; then
  echo "error: could not derive the project slug from origin remote ('$REMOTE_URL')." >&2
  exit 1
fi

# ─── resolve the job(s) to inspect ────────────────────────────────────────────
JOBS_JSON=$(curl -sS -H "Circle-Token: $CC_TOKEN" \
  "https://circleci.com/api/v2/workflow/$WORKFLOW_ID/job")

# Emits "job_number<TAB>job_name" lines for each job we should inspect.
JOB_ROWS=$(printf '%s' "$JOBS_JSON" | JOB_NAME="$JOB_NAME" python3 -c "
import json, os, sys
data = json.load(sys.stdin)
want = os.environ.get('JOB_NAME', '')
rows = []
for j in data.get('items', []):
    n, s, num = j.get('name'), j.get('status'), j.get('job_number')
    if want:
        if n == want and num:
            rows.append((num, n))
    elif s == 'failed' and num:
        rows.append((num, n))
for num, n in rows:
    print('%s\t%s' % (num, n))
" | tr -d '\r')

if [[ -z "$JOB_ROWS" ]]; then
  if [[ -n "$JOB_NAME" ]]; then
    echo "error: could not locate '$JOB_NAME' (with a job_number) in workflow $WORKFLOW_ID." >&2
  else
    echo "(no failed jobs found in workflow $WORKFLOW_ID — the failure may be at the" >&2
    echo " infrastructure layer, or jobs haven't started yet)" >&2
  fi
  exit 3
fi

# ─── pull step outputs for failed actions, per job ────────────────────────────
while IFS=$'\t' read -r JOB_NUMBER JNAME; do
  [[ -z "$JOB_NUMBER" ]] && continue
  echo "########## JOB: $JNAME (#$JOB_NUMBER) ##########"
  TMP_JOB_JSON=$(mktemp)
  curl -sS -H "Circle-Token: $CC_TOKEN" \
    "https://circleci.com/api/v1.1/project/$PROJECT_V1/$JOB_NUMBER" \
    -o "$TMP_JOB_JSON"

  TAIL_LINES="$TAIL_LINES" JOB_JSON="$TMP_JOB_JSON" python3 <<'PY'
import json, os, sys, urllib.request, gzip

tail_lines = int(os.environ.get("TAIL_LINES", "300"))
with open(os.environ["JOB_JSON"]) as fh:
    data = json.load(fh)
steps = data.get("steps") or []

failed = []
for step in steps:
    for action in step.get("actions") or []:
        if action.get("failed") or action.get("status") == "failed":
            failed.append((step.get("name"), action))
        else:
            ec = action.get("exit_code")
            if ec not in (None, 0):
                failed.append((step.get("name"), action))

if not failed:
    print("(no failed steps found — the job may have been canceled before any step ran,")
    print(" or the failure was at the infrastructure layer with no per-step output)")
    sys.exit(0)

def fetch(url):
    with urllib.request.urlopen(url) as resp:
        raw = resp.read()
    try:
        raw = gzip.decompress(raw)
    except OSError:
        pass
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, list):
            return "".join(ch.get("message", "") for ch in parsed if isinstance(ch, dict))
    except Exception:
        pass
    return raw.decode("utf-8", errors="replace")

for name, action in failed:
    print(f"=== STEP: {name}  (exit_code={action.get('exit_code')}, status={action.get('status')}) ===")
    url = action.get("output_url")
    if not url:
        print("(no output_url — step produced no captured stdout/stderr)\n")
        continue
    try:
        text = fetch(url)
    except Exception as exc:
        print(f"(failed to fetch step output: {exc})\n")
        continue
    lines = text.splitlines()
    if len(lines) > tail_lines:
        print(f"... ({len(lines) - tail_lines} earlier lines omitted; showing last {tail_lines}) ...")
        lines = lines[-tail_lines:]
    print("\n".join(lines))
    print()
PY
  rm -f "$TMP_JOB_JSON"
done <<EOF
$JOB_ROWS
EOF
