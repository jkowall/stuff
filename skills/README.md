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

Copy the skill directories you want directly into each assistant's skills folder.
Check for a same-named existing copy first if you have local customizations.

### macOS / Linux

```bash
cp -r skills/<skill-name> ~/.claude/skills/
cp -r skills/<skill-name> ~/.codex/skills/
```

### Windows

```powershell
Copy-Item -Recurse skills\<skill-name> ~\.claude\skills\
Copy-Item -Recurse skills\<skill-name> ~\.codex\skills\
```

Restart or open a new assistant session after installation so it refreshes its skill
catalog. Re-run the same copy after pulling repository updates to pick up changes.

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
