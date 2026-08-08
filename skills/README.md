# Workflow Skills

These procedural skills package recurring evidence-heavy workflows. They define a
stable input contract, a repeatable process, mutation guardrails, a compact output,
and an explicit stopping condition. They do not contain credentials, customer data,
private communications, or private or internal identifiers.

## Catalog

| Skill | Use it for | Terminal result |
|---|---|---|
| [`maintainer-pr-review`](maintainer-pr-review/SKILL.md) | Exact-head GitHub review, approval, merge queue, and merge verification | Exact-head decision or verified merged/blocker state |
| [`dependency-alert-remediation`](dependency-alert-remediation/SKILL.md) | Cross-repository dependency and security-alert cleanup | Live disposition for every in-scope alert |
| [`spacelift-artifact-reconciliation`](spacelift-artifact-reconciliation/SKILL.md) | Reconciling Spacelift decks, roadmaps, briefs, and strategy sources | Traceable changes plus explicit decision questions |
| [`macos-updater-health`](macos-updater-health/SKILL.md) | Diagnosing scheduled macOS updater, phase, cache, PATH, and prerelease-channel health | Proven health, localized cause, or exact evidence blocker |
| [`feature-feedback-batch-cleanup`](feature-feedback-batch-cleanup/SKILL.md) | Deterministic, resumable cleanup of a Featurebase or product-feedback backlog | Reconciled batch ledger and exact resume point |
| [`contract-change-review`](contract-change-review/SKILL.md) | Reviewing contract redlines, amendments, placeholders, and execution readiness | Classified findings register and optional unsent response draft |
| [`validated-upstream-proposal`](validated-upstream-proposal/SKILL.md) | Turning technical feedback into a validated upstream design and PR plan | Publish-ready proposal or exact evidence blocker |

`feature-feedback-batch-cleanup` coordinates an installed single-item feedback
triage policy when one is available. That policy remains the authority for per-item
classification, scoring, routing, and response drafting; this repository does not
duplicate private product knowledge.

## Install or Update

Run the command from the repository root. Preview first if the destination already
contains skills with the same names.

### macOS

```bash
./backup/LLM_Sync_Mac.sh install-repo-skills --dry-run
./backup/LLM_Sync_Mac.sh install-repo-skills
```

### Linux

```bash
./backup/LLM_Sync_Linux.sh install-repo-skills --dry-run
./backup/LLM_Sync_Linux.sh install-repo-skills
```

### Windows

```powershell
.\backup\LLM_Sync_Win.ps1 -Action install-repo-skills -DryRun
.\backup\LLM_Sync_Win.ps1 -Action install-repo-skills
```

The installer validates that every package has frontmatter with a matching `name`
and a non-empty `description`, copies the packages into the canonical `~/.skills`
store, and mirrors them into `~/.codex/skills` and `~/.claude/skills`. It does not
delete unrelated skills. If a same-named installed
copy differs, the previous copy is preserved below
`~/.skills/.conflicts/repo-install/<timestamp>/` before replacement.

Dry-run output distinguishes packages that would change from packages already
current and reports the planned totals without claiming that archives were written.

The install, audit, and skill-sync actions do not require an LLM backup config file.
Backup and restore actions still require the platform-specific private JSON config.
Restart or open a new assistant session after installation so it refreshes its skill
catalog. Re-run the same install command after pulling repository updates.

## Safety Model

- A skill's instructions do not authorize external writes. Posting, sending,
  approving, merging, signing, deleting, scheduling, or changing external state
  still requires the user's explicit authorization.
- Current primary evidence and repository-local instructions outrank remembered or
  summarized state.
- Private source material may be used inside an authorized session but must not be
  copied into this public repository or an unapproved public output.
- Contract review is informational support, not legal advice; licensed counsel must
  review legal conclusions and final language before execution.
