#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_root="$repo_root/plugins/awesome-skills"

required_files=(
  "$repo_root/.agents/plugins/marketplace.json"
  "$repo_root/.claude-plugin/marketplace.json"
  "$plugin_root/.codex-plugin/plugin.json"
  "$plugin_root/.claude-plugin/plugin.json"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing required file: $file" >&2
    exit 1
  fi
done

python3 -m json.tool "$repo_root/.agents/plugins/marketplace.json" >/dev/null
python3 -m json.tool "$repo_root/.claude-plugin/marketplace.json" >/dev/null
python3 -m json.tool "$plugin_root/.codex-plugin/plugin.json" >/dev/null
python3 -m json.tool "$plugin_root/.claude-plugin/plugin.json" >/dev/null

while IFS= read -r skill_file; do
  skill_dir="$(dirname "$skill_file")"
  skill_name="$(basename "$skill_dir")"
  if [[ ! "$skill_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "invalid skill directory name: $skill_name" >&2
    exit 1
  fi
done < <(find "$plugin_root/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -print | sort)

skill_count="$(find "$plugin_root/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -print | wc -l | tr -d ' ')"
if [[ "$skill_count" -eq 0 ]]; then
  echo "no skills found under $plugin_root/skills" >&2
  exit 1
fi

# ── version: all three manifests must agree ──────────────────────────────────
read_ver() {
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['plugins'][0]['version'] if 'plugins' in d else d['version'])" "$1"
}
mp_ver="$(read_ver "$repo_root/.claude-plugin/marketplace.json")"
cc_ver="$(read_ver "$plugin_root/.claude-plugin/plugin.json")"
cx_ver="$(read_ver "$plugin_root/.codex-plugin/plugin.json")"
if [[ "$mp_ver" != "$cc_ver" || "$mp_ver" != "$cx_ver" ]]; then
  echo "error: version mismatch across manifests: marketplace=$mp_ver claude=$cc_ver codex=$cx_ver" >&2
  echo "Bump all three to the same version." >&2
  exit 1
fi

# ── enforce a version bump when skills or manifests changed ──────────────────
# Clients cache the plugin by version; a content-only edit under skills/ never
# reaches users unless the version is bumped. If anything in the watched paths
# differs from HEAD but the version still equals HEAD's, fail loudly.
if git -C "$repo_root" rev-parse HEAD >/dev/null 2>&1; then
  # NB: marketplace.json is intentionally NOT watched here — it holds every
  # plugin's version, so bumping html-ppt/navi-recap would otherwise falsely
  # demand a core-bundle bump. The mp_ver==cc_ver==cx_ver agreement check above
  # already keeps the bundle's marketplace entry in sync.
  watch_paths=(
    "plugins/awesome-skills/skills"
    "plugins/awesome-skills/.claude-plugin/plugin.json"
    "plugins/awesome-skills/.codex-plugin/plugin.json"
  )
  changed="$(git -C "$repo_root" status --porcelain -- "${watch_paths[@]}")"
  if [[ -n "$changed" ]]; then
    head_ver="$(git -C "$repo_root" show HEAD:.claude-plugin/marketplace.json 2>/dev/null \
      | python3 -c "import json,sys;print(json.load(sys.stdin)['plugins'][0]['version'])" 2>/dev/null || true)"
    if [[ -n "$head_ver" && "$head_ver" == "$mp_ver" ]]; then
      echo "error: skills or manifests changed but version is still $mp_ver (same as HEAD)." >&2
      echo "Bump the version in all three manifests before publishing. Changed paths:" >&2
      printf '%s\n' "$changed" | sed 's/^/  /' >&2
      exit 1
    fi
  fi
fi

# ── ppt-kit drift guard ──────────────────────────────────────────────────────
# The html-ppt plugin and navi-recap's ppt-kit/ are both vendored from the same
# upstream by scripts/update-ppt.sh. Each carries an UPSTREAM.json sha stamp;
# if the two disagree, someone re-vendored one but not the other (drift).
ppt_stamps=(
  "$repo_root/plugins/html-ppt/skills/html-ppt/UPSTREAM.json"
  "$repo_root/plugins/navi-recap/skills/navi-recap/ppt-kit/UPSTREAM.json"
)
ppt_shas=()
for stamp in "${ppt_stamps[@]}"; do
  if [[ -f "$stamp" ]]; then
    python3 -m json.tool "$stamp" >/dev/null
    ppt_shas+=("$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha'])" "$stamp")")
  fi
done
if [[ "${#ppt_shas[@]}" -eq 2 && "${ppt_shas[0]}" != "${ppt_shas[1]}" ]]; then
  echo "error: ppt-kit drift — html-ppt sha=${ppt_shas[0]:0:10} but navi-recap ppt-kit sha=${ppt_shas[1]:0:10}." >&2
  echo "Re-run ./scripts/update-ppt.sh so both vendor the same upstream commit." >&2
  exit 1
fi

# ── per-plugin guard for the html-ppt / navi-recap plugins ───────────────────
# Each must (a) keep its version in sync across its 3 manifests, and (b) bump
# that version whenever its skill content changes (clients cache by version, so
# a re-vendor or hand-edit that skips the bump never reaches users). update-ppt.sh
# auto-bumps on re-vendor; this gate also catches manual edits.
entry_ver() { # $1 = plugin name → its version in the root marketplace.json
  python3 -c "import json,sys;d=json.load(open('$repo_root/.claude-plugin/marketplace.json'));print(next((p['version'] for p in d['plugins'] if p['name']==sys.argv[1]),''))" "$1"
}
gate_plugin() { # $1 = plugin name, $2 = managed content path (rel to repo root)
  local name="$1" managed="$2"
  local cc="$repo_root/plugins/$name/.claude-plugin/plugin.json"
  local cx="$repo_root/plugins/$name/.codex-plugin/plugin.json"
  [[ -f "$cc" && -f "$cx" ]] || return 0
  python3 -m json.tool "$cc" >/dev/null
  python3 -m json.tool "$cx" >/dev/null
  local cc_v cx_v mp_v
  cc_v="$(read_ver "$cc")"; cx_v="$(read_ver "$cx")"; mp_v="$(entry_ver "$name")"
  if [[ "$cc_v" != "$cx_v" || "$cc_v" != "$mp_v" ]]; then
    echo "error: $name version mismatch: marketplace=$mp_v claude=$cc_v codex=$cx_v" >&2
    exit 1
  fi
  # bump-on-change (skip UPSTREAM.json so a synced_at-only touch isn't gated)
  git -C "$repo_root" rev-parse HEAD >/dev/null 2>&1 || return 0
  local changed head_v
  changed="$(git -C "$repo_root" status --porcelain -- "$managed" | grep -v 'UPSTREAM.json' || true)"
  [[ -z "$changed" ]] && return 0
  head_v="$(git -C "$repo_root" show "HEAD:plugins/$name/.claude-plugin/plugin.json" 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['version'])" 2>/dev/null || true)"
  if [[ -n "$head_v" && "$head_v" == "$cc_v" ]]; then
    echo "error: $name skill content changed but version is still $cc_v (same as HEAD)." >&2
    echo "Bump $name across its 3 manifests (update-ppt.sh does this automatically on re-vendor)." >&2
    exit 1
  fi
}
gate_plugin html-ppt   "plugins/html-ppt/skills/html-ppt"
gate_plugin navi-recap "plugins/navi-recap/skills/navi-recap"

echo "ok: $skill_count skills, version $mp_ver, plugin metadata validated; ppt-kit sha ${ppt_shas[0]:0:10}"
