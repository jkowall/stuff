---
name: spacelift-artifact-reconciliation
description: Reconcile a Spacelift deck, roadmap, strategy document, brief, or planning artifact against current source material without erasing conflicts. Use when several sources disagree, a delivery artifact may be stale, or facts, proposals, and decisions must be separated before editing or recommending a decision.
license: Apache-2.0
metadata:
  generated: "2026-08-03"
  scope: Spacelift product and design artifacts
---

# Spacelift artifact reconciliation

Reconcile the artifact to the evidence. Do not make inconsistent sources look
consistent by silently choosing one. The useful result is a trustworthy artifact,
an explicit conflict, or a focused decision question.

## Inputs

Collect these before reconciling:

- the subject and decision or communication the artifact must support
- the current target artifact, including its location, version, and intended audience
- the relevant source artifacts, with links or paths where available
- the delivery date and any owner or approver already named
- the requested output: findings, change plan, revised draft, or decision brief
- known constraints, terminology, and claims that must be verified exactly

If the current target artifact is unavailable, say so and stop before proposing
line-level changes. If a non-critical source is unavailable, record the gap and
continue only when the remaining evidence can support a bounded conclusion.

## Evidence rules

1. Read the current target artifact first. Do not rely on a prior export, summary,
   screenshot, or memory when the live artifact is available.
2. Prefer current primary sources and explicit decisions over summaries of them.
3. Record source dates and versions. Recency alone does not establish authority.
4. Treat comments, AI artifacts, working notes, and observed application state as
   context unless they contain an explicit decision by an accountable owner.
5. Separate source facts from proposed additions. Never present a recommendation as
   something a source already decided.
6. Applicable private project context may guide the session, but never copy private
   communications, credentials, customer data, internal identifiers, or confidential
   examples into a public artifact or this public skill repository.

## Procedure

### 1. Define the reconciliation boundary

State the target artifact, audience, decision it supports, required output, and the
latest acceptable source date. Identify which sections and claims are in scope.

### 2. Build a source inventory

For each source, record:

| Source | Version or as-of date | Owner | Status | Relevant sections |
| --- | --- | --- | --- | --- |
| Current artifact | exact version | named owner if known | live/draft | sections |

Use status values such as `live`, `approved`, `working`, `superseded`, or `unknown`.
Do not label a source approved without evidence.

### 3. Build the dated claim ledger

Extract every material claim that could change the artifact's meaning. Use one row
per claim:

| ID | Claim | Type | Source | As-of date | Confidence | Target impact |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | concise claim | fact/proposal/decision | source section | date | high/medium/low | keep/change/question |

Use the types precisely:

- `fact`: observable or documented current state
- `proposal`: an option, draft, forecast, or recommendation not yet decided
- `decision`: an explicit choice with sufficient owner and decision evidence

Quote sparingly. Preserve exact names, numbers, dates, and qualifiers when they are
material.

### 4. Identify and preserve conflicts

Compare claims that address the same scope, date, owner, metric, or commitment.
Classify each difference as one of:

- compatible detail
- stale source
- terminology mismatch
- scope mismatch
- unresolved contradiction
- explicit change of decision

Do not resolve a contradiction merely because one source is newer or formatted more
formally. Show both positions, their evidence, and the practical consequence.

### 5. Determine artifact changes

For every proposed change, link it to claim-ledger IDs and classify it as:

- correction supported by evidence
- clarification that preserves the source meaning
- proposed addition requiring approval
- removal of stale or unsupported content
- blocked by an unresolved decision

When editing is authorized, make the smallest coherent change. Preserve intentional
voice and structure, and do not rewrite unaffected sections.

### 6. Ask the decision question

Convert every material unresolved contradiction into one answerable question:

> Decision required: choose **A** or **B** for **scope** by **date**. The choice
> changes **specific artifact section or commitment**. Evidence: **claim IDs**.

Name the decision owner only when the sources establish one. Do not invent an owner
or silently pick a side.

### 7. Verify the result

Re-read the changed artifact or draft and confirm:

- every material statement maps to a dated claim-ledger entry
- proposals and decisions are labeled accurately
- conflicts and open questions remain visible
- names, numbers, dates, quotations, and links match their sources
- no private or customer-specific material crossed into a public output

## Output

Lead with the recommended next action. Then provide:

1. reconciliation scope and source inventory
2. dated claim ledger
3. conflicts and their consequences
4. traceable change plan or revised draft
5. decision questions, owners if known, and due dates if established
6. evidence gaps and residual risks

## Guardrails

- Never silently harmonize roadmap, strategy, planning, and presentation sources.
- Never infer commitment from placement on a roadmap or slide.
- Never claim a proposal is approved without explicit decision evidence.
- Never expose private communications, customer data, credentials, or sensitive
  internal identifiers in a public artifact.
- Do not publish, send, comment, or alter external systems without explicit approval.

## Stopping conditions

The reconciliation is complete when every in-scope material claim is sourced and
typed, every conflict is either resolved by evidence or converted into a decision
question, and every proposed artifact change is traceable to the ledger.

Stop with an evidence blocker when the current artifact cannot be read, a required
claim depends on inaccessible evidence, or mutually exclusive sources cannot be
resolved without an accountable decision.
