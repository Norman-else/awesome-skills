---
name: remote-github-pr
description: Create or update a GitHub pull request entirely through remote GitHub operations without cloning a repository locally. Use this skill whenever the user asks to modify GitHub-hosted code with `gh`, GitHub APIs, or direct remote edits, especially when they explicitly say not to clone the repo, want a new branch plus PR, or only need a small surgical change in an existing file.
---

# Remote GitHub PR

Use this skill when the user wants a change made directly on GitHub without a local clone or local worktree.

## Core rules

- Do not clone the repository.
- Do not create or edit local copies of the target repo just to make the change.
- Prefer `gh api` REST calls over GraphQL when either works.
- Make the smallest possible remote change that fully satisfies the request.
- Do not open a PR until you have verified the remote branch contains the intended diff.

## When this skill is a good fit

- The user says `不用克隆代码到本地`, `直接用gh远程修改`, `直接提PR`, or similar.
- The change is focused and can be made by editing one or a few existing files remotely.
- The repo is on GitHub and the current `gh` session has permission to read, push, and open PRs.

## When to stop and realign

- The repo cannot be identified confidently from the user's wording.
- The change is broad enough that reading many files locally would normally be safer.
- The remote edit would require generating many new files or doing multi-file refactors with high risk.
- The target file cannot be found remotely or the repo permissions are insufficient.

## Workflow

1. Identify the repository.
2. Confirm `gh auth status` succeeds.
3. Discover the target file and current content remotely.
4. Read only the minimum content needed to understand the requested change.
5. Create a new remote branch from the default branch or the user-specified base branch.
6. Apply the change through GitHub APIs.
7. Read the changed file back from the new branch.
8. Compare the branch against base and verify the final diff is exactly what was intended.
9. Create the PR only after the diff is clean.
10. Return the PR URL and summarize the final remote change.

## Repo discovery

Prefer this order:

1. If the user gives `owner/repo`, use it directly.
2. If the user gives a product or service nickname like `backend crm`, search likely GitHub repos with `gh search repos`.
3. If multiple repos are plausible, stop and ask the user which one they mean.

Useful commands:

```powershell
gh auth status
gh search repos "backend crm org:Mercaso" --limit 20
gh api repos/OWNER/REPO --jq '.default_branch'
gh api repos/OWNER/REPO/git/trees/BRANCH?recursive=1
```

## Remote file editing

Prefer the GitHub Contents API for small file edits:

1. Read the current file SHA and content from the base branch.
2. Decode the content carefully.
3. Apply a precise text change.
4. Upload the updated file to the feature branch with the current file SHA.

For content reads, strip newlines from base64 before decoding:

```powershell
$b64 = gh api repos/OWNER/REPO/contents/path/to/file?ref=master --jq .content
$text = [System.Text.Encoding]::UTF8.GetString(
  [System.Convert]::FromBase64String(($b64 -replace "`r|`n", ""))
)
```

## Safety checks for edits

- Prefer exact string replacement over clever regex when the target text is short and stable.
- If regex is necessary, verify the replacement result before uploading.
- If the replacement does not change the text, stop and inspect the source instead of forcing a write.
- After writing, always read the file back from the feature branch.
- Always inspect the compare diff before creating the PR.

## Branch creation

Create a dedicated feature branch remotely from the base branch commit SHA.

Suggested naming:

- `codex/<short-task-slug>`
- include a date suffix when collision risk is high

Example:

```powershell
$baseSha = gh api repos/OWNER/REPO/git/ref/heads/master --jq .object.sha
gh api -X POST repos/OWNER/REPO/git/refs -f ref="refs/heads/codex/my-change" -f sha="$baseSha"
```

## Diff verification

Always compare the feature branch to base before opening the PR:

```powershell
gh api repos/OWNER/REPO/compare/master...codex/my-change
```

Review:

- `ahead_by`
- changed files
- patch content

Do not create the PR if the diff contains accidental deletions, empty-file writes, malformed replacements, or unrelated changes.

## Recovery

If a remote write goes wrong:

- Do not open the PR.
- Fix the same branch with a corrective commit.
- Re-run file readback and compare checks.
- Only continue once the final diff matches the requested change.

## PR creation

Use a concise title and body that explain:

- what changed
- why it changed
- how you verified it remotely

Example:

```powershell
gh pr create --repo OWNER/REPO --base master --head codex/my-change --title "Increase prod memory limit to 1024Mi" --body "## Summary
- update prod deploy memory limit to 1024Mi

## Verification
- read back the changed file from the remote branch
- compared feature branch against master and confirmed the final diff is only the intended line change"
```

## Response checklist

Before telling the user the work is done, confirm all of these are true:

- repo identified
- auth valid
- branch created
- file changed remotely
- changed file read back successfully
- compare diff matches intent
- PR created successfully

## Example triggers

- `不用克隆代码到本地，直接用 gh 改一下然后提 PR`
- `remote edit this GitHub repo and open a PR`
- `直接在 GitHub 上改配置文件，创建新分支`
- `use gh only, no local checkout`
