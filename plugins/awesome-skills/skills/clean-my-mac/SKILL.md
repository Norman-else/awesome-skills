---
name: clean-my-mac
description: Safely audit and clean macOS disk usage by identifying temporary files, caches, build artifacts, stale development environments, and other disposable data. Also explain macOS storage usage by analyzing data-volume usage, large directory groups, snapshots, and category mismatches with System Settings. Use when Codex needs to help free disk space on a Mac, clean up junk files, remove caches, inspect large stale files, explain why storage usage looks high, diagnose System Settings storage discrepancies, or respond to requests like "clean my mac", "free up disk space", "remove temp files", "disk cleanup", "why is my Mac storage so high", or "explain my storage". Always show a dry-run summary first and require explicit user confirmation before deleting anything.
---

# Clean My Mac

## Overview

Use this skill to run a careful Mac cleanup workflow with strong safety guardrails. Audit first, summarize findings with sizes and paths, ask for confirmation, then delete only the approved items and report how much space was freed.

This skill has two modes:

- Cleanup mode: find safe cleanup candidates, summarize them, and delete only after confirmation
- Storage explanation mode: run a read-only diagnosis to explain where storage is going and why macOS System Settings may not match simple shell totals

## Safety Rules

Follow these rules exactly:

1. Show a dry-run summary before every deletion step.
2. Ask for explicit user confirmation before deleting anything.
3. Delete only disposable files that fit the categories in this skill.
4. Never delete user documents, source code, or project files.
5. Never delete files inside an active git working tree.
6. Respect any user-provided exclusions.
7. Avoid broad destructive commands against system-critical paths.
8. Report disk usage before and after cleanup.

If a deletion touches protected paths or requires elevated privileges, request escalation first and explain exactly what will be removed.

## Default Assumptions

If the user does not specify otherwise:

- Scan the home directory and standard cache locations
- Start in dry-run mode
- Skip categories the user explicitly opts out of
- Prefer per-category confirmation over one giant delete step

If the user asks to explain storage rather than clean it, default to storage explanation mode and do not propose deletions unless the user asks for cleanup after the diagnosis.

## macOS Storage Accounting Note

Do not use `df -h /` as the sole storage baseline on macOS. Modern macOS uses APFS volume groups, and the root volume can under-report the real user-visible storage usage shown in System Settings.

When reporting storage:

- Prefer `df -h ~` for the user's writable data volume view
- Also check `/System/Volumes/Data` when available
- Treat `du` summaries of user and cache directories as cleanup-scope measurements, not full-disk truth
- Explain that System Settings may still show `Calculating...` and can include snapshots, app support data, Mail attachments, Messages data, iCloud-managed files, and purgeable space that this skill does not fully enumerate
- Keep "space freed by approved deletions" separate from "total disk used by macOS"

## Workflow

### 0. Choose the mode

Pick the mode based on the request:

- Use cleanup mode for requests to clean, free space, remove junk, or delete caches
- Use storage explanation mode for requests to explain storage, diagnose why usage is high, compare against System Settings, or understand what is taking space

In storage explanation mode, keep the entire run read-only unless the user later asks to clean specific findings.

### 1. Capture the baseline

Start by measuring disk usage from the data-volume perspective:

```bash
df -h ~
df -h /System/Volumes/Data 2>/dev/null
du -sh ~/Library/Caches ~/Library/Logs /tmp ~/Downloads 2>/dev/null
du -sh ~/Applications /Applications /Library ~/Library 2>/dev/null
```

Use this as the before snapshot in the final report. If the numbers differ from System Settings, explicitly say the skill is measuring cleanup-relevant storage views rather than reproducing Apple's full category accounting.

### Storage explanation mode

When the user asks for explanation rather than cleanup, run a read-only breakdown after the baseline.

Focus on these areas:

- Data volume usage: `df -h ~` and `/System/Volumes/Data`
- Major user and system groups: `~/Library`, `/Library`, `/Applications`, `~/Applications`
- High-signal user data sources: `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Mobile Documents`, `~/Library/Messages`, `~/Library/Mail`
- Media and personal content: `~/Pictures`, `~/Movies`, `~/Music`, `~/Documents`, `~/Desktop`
- APFS local snapshots via `tmutil listlocalsnapshots /`
- Cleanup-scope directories like caches, logs, downloads, and trash

Useful read-only commands:

```bash
du -sh ~/Library ~/Library/Application\ Support ~/Library/Containers ~/Library/Mobile\ Documents ~/Library/Messages ~/Library/Mail 2>/dev/null
du -sh ~/Pictures ~/Movies ~/Music ~/Documents ~/Desktop 2>/dev/null
du -sh /Applications ~/Applications /Library 2>/dev/null
tmutil listlocalsnapshots / 2>/dev/null
```

Use targeted follow-up `du` commands on any suspiciously large subtree instead of scanning the whole disk recursively when a narrower query will answer the question.

The goal in this mode is to explain:

- Which large buckets are visible from the shell
- Which categories are likely represented in System Settings but not fully enumerable with `du`
- Why there may still be a gap between shell totals and Apple's UI

Do not turn storage explanation mode into cleanup mode automatically.

### 2. Find task-created temporary files

Look for likely disposable files created by earlier AI or shell tasks:

```bash
find ~ -maxdepth 2 -name "*.sh" -mtime -30 2>/dev/null
find ~ -maxdepth 2 -name "*.py" -mtime -30 2>/dev/null
find /tmp ~ -maxdepth 2 \( -name "*.tmp" -o -name "temp_*" -o -name "output_*" \) -not -path "*/.*" 2>/dev/null
find ~ -maxdepth 3 \( -name ".env.tmp" -o -name ".env.test" \) 2>/dev/null
```

Treat these as candidates only. Do not delete anything the user asked to keep, any intentionally named output file, or any production log.

### 3. Audit caches

Scan common cache and temp directories, then show the biggest offenders:

```bash
du -sh ~/Library/Caches/* 2>/dev/null | sort -rh | head -20
du -sh /tmp /var/folders ~/Library/Caches 2>/dev/null
du -sh ~/Library/Developer/Xcode/DerivedData ~/Library/Developer/Xcode/iOS\ DeviceSupport 2>/dev/null
du -sh /cores 2>/dev/null
```

Useful targets include:

- `~/Library/Caches/`
- `/tmp/`
- `/var/folders/`
- Safari, Chrome, Slack, Spotify cache directories if present
- Xcode DerivedData and iOS DeviceSupport
- Core dumps

Let the user choose which cache directories to purge.

### 4. Audit developer residuals and build artifacts

Check for common development leftovers and summarize by category.

Node.js:

```bash
find ~ -name "node_modules" -type d -prune 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh
find ~ \( -name ".npm" -o -name ".yarn" -o -name ".pnpm-store" \) -type d -prune 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh
```

Python caches and environments:

```bash
find ~ -name "__pycache__" -type d 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh
find ~ -name "*.pyc" -type f 2>/dev/null
du -sh ~/Library/Caches/pip ~/Library/Caches/pypoetry 2>/dev/null
find ~ \( -name ".venv" -o -name "venv" -o -name "env" \) -type d -prune 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh | head -30
```

Conda and pyenv:

```bash
du -sh ~/.pyenv/versions 2>/dev/null
du -sh ~/miniforge3/envs ~/anaconda3/envs ~/miniconda3/envs ~/opt/anaconda3/envs 2>/dev/null
```

For conda environments, use `conda-meta` modification time as the last-used proxy and mark environments older than 15 days as removal candidates. Always show the list first and never remove the base environment.

Java, Go, Rust:

```bash
du -sh ~/.gradle/caches ~/.m2/repository ~/go/pkg/mod/cache ~/.cargo/registry/cache 2>/dev/null
```

Docker and Homebrew:

```bash
docker system df 2>/dev/null
brew cleanup --dry-run 2>/dev/null
```

If Docker is running, offer `docker system prune -f` only after confirmation. Offer `brew cleanup` only after showing the dry-run output.

When evaluating virtual environments or dependency folders, avoid deleting anything under a recently active project. If a parent project looks recently used, surface it to the user and skip by default.

### 5. Find large stale files

Search for large, old files while staying away from user content:

```bash
find ~ -not -path "*/.*" -size +500M -mtime +30 -type f 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh | head -20
find ~/Downloads -size +100M -mtime +14 -type f 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh
```

Do not recommend deleting:

- Files in `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Music`, or `~/Movies`
- Anything inside a git repository
- Application bundles ending in `.app`

Let the user decide file by file.

### 6. Review trash and old logs

Inspect trash and aged logs:

```bash
du -sh ~/.Trash 2>/dev/null
find ~/Library/Logs -name "*.log" -mtime +30 -type f 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh
```

Offer to empty Trash or delete old user log files only after confirmation. Do not remove logs that are actively used by the system.

### 7. Present the deletion plan

Before deleting anything, provide a compact summary with:

- Category
- Exact path
- Estimated size
- Reason it is considered safe to remove

Ask a direct confirmation question that makes the scope obvious.

Example:

```text
Dry run summary
- Cache: ~/Library/Caches/com.spotify.client (1.2G)
- Build artifact: ~/project-a/node_modules (780M)
- Python cache: ~/repo-b/__pycache__ (42M)

Delete these three items only?
```

### 8. Execute approved deletions carefully

Delete only the approved items with targeted commands. Prefer the narrowest command possible:

```bash
rm -rf ~/Library/Caches/com.spotify.client
rm -rf ~/some/project/__pycache__
conda env remove -n old-env --yes
docker system prune -f
brew cleanup
```

Do not combine unrelated deletions into a single broad wildcard command.

### 9. Report results

After deletion, re-run:

```bash
df -h ~
df -h /System/Volumes/Data 2>/dev/null
```

Summarize the outcome by category and total space freed.

Do not claim the final `df` numbers exactly match System Settings. Instead, report:

- Space freed by the deletions that were actually performed
- Updated `df -h ~` and `/System/Volumes/Data` values
- Updated `du` totals for the directories inspected
- A short note when macOS category accounting may still differ

Use a format like:

```text
Mac cleanup complete
- Task temp files: freed X MB
- Caches: freed X GB
- Dev artifacts: freed X GB
- Large stale files: freed X MB
- Trash and logs: freed X MB

Total freed: X.X GB
Data volume after: X used / X total
Inspected directories after: Caches X, Logs Y, Downloads Z
Note: macOS System Settings may still differ because it includes snapshots, app data, and other system-managed storage categories.
```

## Deletion Boundaries

Never delete these automatically:

- User documents and media
- Source code and checked-in files
- Any path inside a git worktree
- Active database files
- Unknown hidden directories with unclear ownership
- Anything the user did not explicitly approve

If a candidate is ambiguous, keep it in the report and ask instead of guessing.

## Exception Handling

- Permission denied: skip the item, mention it briefly, and continue
- File not found: ignore it and continue
- Docker not running: skip Docker cleanup and mention it was skipped
- Xcode not installed: skip Xcode-specific cleanup silently
- User says "skip X": mark that category as skipped in the final report

## Output Style

Keep the cleanup process easy to review:

- Group findings by category
- Show paths and human-readable sizes
- Keep deletion prompts specific
- End with a concise before/after summary

For storage explanation mode, use this structure:

- Data volume summary
- Largest visible buckets
- Likely hidden or system-managed contributors
- Why System Settings may differ
- Optional next cleanup opportunities, only if the user asked for them
