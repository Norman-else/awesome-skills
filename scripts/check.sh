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
  watch_paths=(
    "plugins/awesome-skills/skills"
    ".claude-plugin/marketplace.json"
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

echo "ok: $skill_count skills, version $mp_ver, plugin metadata validated"
