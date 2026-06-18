#!/usr/bin/env bash
# update-ppt.sh — re-vendor the html-ppt design system from upstream.
#
# Upstream (lewislulu/html-ppt-skill) is a bare AgentSkill repo, NOT a plugin.
# This script pulls its *skill content* (themes / layouts / animations /
# runtime + presenter mode / render script) and vendors it into the two
# consumer plugins in this marketplace. The plugin *shells* (.claude-plugin/,
# .codex-plugin/, marketplace entries, versions) and navi-recap's own files
# (SKILL.md, references, examples, house theme) are NEVER touched — they live
# outside the script-managed directories.
#
#   plugins/html-ppt/skills/html-ppt/        <- wholesale mirror (script-owned)
#   plugins/navi-recap/skills/navi-recap/ppt-kit/  <- design subset (script-owned)
#
# Tracks upstream `main` by default. Run manually whenever you want to refresh:
#   ./scripts/update-ppt.sh
# Then review the diff, bump versions, and run ./scripts/check.sh.
#
# Overrides:
#   HTMLPPT_SOURCE=<url|local-path>   default: https://github.com/lewislulu/html-ppt-skill.git
#   HTMLPPT_REF=<branch|tag|sha>      default: main   (ignored for local-path sources)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${HTMLPPT_SOURCE:-https://github.com/lewislulu/html-ppt-skill.git}"
REF="${HTMLPPT_REF:-main}"

html_ppt_dir="$repo_root/plugins/html-ppt/skills/html-ppt"
navi_kit_dir="$repo_root/plugins/navi-recap/skills/navi-recap/ppt-kit"

# ── 1. Obtain a clean upstream tree + its commit sha ─────────────────────────
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
src=""
if [[ -d "$SOURCE/.git" ]]; then
  # Local checkout: copy its working tree, read its HEAD.
  echo "→ source: local checkout $SOURCE"
  rsync -a --exclude='.git/' "$SOURCE"/ "$work/src/"
  sha="$(git -C "$SOURCE" rev-parse HEAD)"
  ref_label="$(git -C "$SOURCE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
else
  echo "→ source: $SOURCE @ $REF (shallow clone)"
  git clone --quiet --depth 1 --branch "$REF" "$SOURCE" "$work/src" \
    || git clone --quiet --depth 1 "$SOURCE" "$work/src"
  sha="$(git -C "$work/src" rev-parse HEAD)"
  ref_label="$REF"
  rm -rf "$work/src/.git"
fi
src="$work/src"
synced_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_stamp() { # $1 = target dir, $2 = scope label
  cat > "$1/UPSTREAM.json" <<JSON
{
  "repo": "https://github.com/lewislulu/html-ppt-skill",
  "ref": "$ref_label",
  "sha": "$sha",
  "scope": "$2",
  "synced_at": "$synced_at",
  "note": "Auto-vendored by scripts/update-ppt.sh. Do not hand-edit this directory; edit upstream or the script."
}
JSON
}

# Re-vendoring is keyed on the upstream sha: if a target already carries this
# exact sha we skip it entirely (true no-op — no churn, no version bump). Pass
# --force (or FORCE=1) to re-vendor regardless, e.g. after changing this script.
FORCE="${FORCE:-}"
[[ "${1:-}" == "--force" ]] && FORCE=1

stamped_sha() { # echo the sha recorded in a target's UPSTREAM.json, or "" if absent
  python3 -c "import json,os,sys;p=sys.argv[1];print(json.load(open(p))['sha'] if os.path.exists(p) else '')" "$1" 2>/dev/null || echo ""
}

# patch-bump a consumer plugin's version across its 3 manifests (the two
# plugin.json files + its entry in the root marketplace.json). Echoes new ver.
bump_plugin() { # $1 = plugin name
  python3 - "$repo_root" "$1" <<'PY'
import json, sys
root, name = sys.argv[1], sys.argv[2]
cc = f"{root}/plugins/{name}/.claude-plugin/plugin.json"
cx = f"{root}/plugins/{name}/.codex-plugin/plugin.json"
mp = f"{root}/.claude-plugin/marketplace.json"
maj, mino, pat = map(int, json.load(open(cc))["version"].split("."))
new = f"{maj}.{mino}.{pat + 1}"
for p in (cc, cx):
    o = json.load(open(p)); o["version"] = new
    json.dump(o, open(p, "w"), indent=2, ensure_ascii=False); open(p, "a").write("\n")
m = json.load(open(mp))
for pl in m["plugins"]:
    if pl["name"] == name:
        pl["version"] = new
json.dump(m, open(mp, "w"), indent=2, ensure_ascii=False); open(mp, "a").write("\n")
print(new)
PY
}

bumps=()

# ── 2. Vendor WHOLESALE into the html-ppt plugin ─────────────────────────────
# Everything except .git and the two heavy, runtime-irrelevant dirs.
if [[ -n "$FORCE" || "$(stamped_sha "$html_ppt_dir/UPSTREAM.json")" != "$sha" ]]; then
  echo "→ vendoring html-ppt (wholesale)"
  mkdir -p "$html_ppt_dir"
  rsync -a --delete \
    --exclude='.git/' \
    --exclude='docs/' \
    --exclude='scripts/verify-output/' \
    --exclude='UPSTREAM.json' \
    "$src"/ "$html_ppt_dir"/
  write_stamp "$html_ppt_dir" "wholesale"
  bumps+=("html-ppt → $(bump_plugin html-ppt)")
else
  echo "→ html-ppt already at ${sha:0:10}; skip"
fi

# ── 3. Vendor the DESIGN SUBSET into navi-recap's ppt-kit/ ────────────────────
# Subset = the design system navi-recap absorbs: themes, layouts, the full
# animation library, the keyboard runtime, and the render script. Rebuilt from
# scratch each run so the mirror stays exact. navi-recap deliberately does NOT
# use presenter mode, so its presenter-specific files are excluded here (the
# S-key code is baked into runtime.js and stays, but is unused/undocumented).
if [[ -n "$FORCE" || "$(stamped_sha "$navi_kit_dir/UPSTREAM.json")" != "$sha" ]]; then
  echo "→ vendoring navi-recap/ppt-kit (design subset, presenter mode excluded)"
  rm -rf "$navi_kit_dir"
  mkdir -p "$navi_kit_dir"/{assets,templates/single-page,scripts}
  rsync -a "$src/assets"/ "$navi_kit_dir/assets"/                       # base.css, fonts.css, runtime.js, themes/, animations/
  rsync -a "$src/templates/single-page"/ "$navi_kit_dir/templates/single-page"/
  # Keep only the pure catalogs navi-recap's own docs point at (themes/layouts/
  # animations). Excluded: presenter-mode.md (unused), full-decks.md (no full-decks
  # vendored), and authoring-guide.md (its speaker-notes/S-key workflow conflicts
  # with navi-recap's no-presenter rule and overlaps navi-recap's own docs).
  [[ -d "$src/references" ]] && rsync -a \
    --exclude='presenter-mode.md' --exclude='full-decks.md' --exclude='authoring-guide.md' \
    "$src/references"/ "$navi_kit_dir/references"/
  # scripts: render (PNG export) + new-deck (scaffold)
  for s in render.sh new-deck.sh; do
    [[ -f "$src/scripts/$s" ]] && install -m 0755 "$src/scripts/$s" "$navi_kit_dir/scripts/$s"
  done
  # preserve MIT attribution alongside the vendored copy
  [[ -f "$src/LICENSE" ]] && cp "$src/LICENSE" "$navi_kit_dir/LICENSE"
  write_stamp "$navi_kit_dir" "design-subset"
  # regenerate the themed single-file template from the freshly vendored ppt-kit
  # so its embedded base.css + 36 themes stay in sync with upstream.
  bash "$repo_root/scripts/build-single-template.sh"
  bumps+=("navi-recap → $(bump_plugin navi-recap)")
else
  echo "→ navi-recap/ppt-kit already at ${sha:0:10}; skip"
fi

# ── 4. Report ────────────────────────────────────────────────────────────────
echo
if [[ "${#bumps[@]}" -eq 0 ]]; then
  echo "✓ already up to date with upstream @ ${ref_label} (${sha:0:10}); nothing changed."
else
  echo "✓ vendored upstream @ ${ref_label} (${sha:0:10}); versions bumped:"
  printf '    %s\n' "${bumps[@]}"
  echo
  echo "Next:"
  echo "  1) review the diff      git -C $repo_root status -s"
  echo "  2) validate             ./scripts/check.sh"
  echo "  3) commit"
fi
