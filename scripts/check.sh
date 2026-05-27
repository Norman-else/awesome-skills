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

echo "ok: $skill_count skills and plugin metadata validated"
