---
name: feature-feedback-batch-cleanup
description: Safely process a multi-item Featurebase or product-feedback backlog in deterministic, resumable batches. Use for oldest-first batch cleanup, batch triage drafts, duplicate review, or an explicitly approved batch of feedback actions that must be verified after each change.
license: Apache-2.0
metadata:
  generated: "2026-08-03"
  mode: batch coordination around an installed single-item triage policy
---

# Feature feedback batch cleanup

Coordinate batch work around the current installed single-item feedback triage
policy. That policy, when available, remains the source of truth for per-item
classification, routing, scoring, and response drafting. Do not copy, replace, or
weaken its judgment rubric here.

This skill adds queue ordering, resumability, evidence checks, approval boundaries,
and post-action verification.

## Single-item policy

Discover and follow the product's installed single-item feedback triage skill or
documented rubric for every item. Read its current knowledge sources before triage.
If no authoritative policy or a required knowledge source is available, inventory
the batch if useful but stop before making classification, routing, or build claims.

## Inputs

Collect:

- the live feedback source and the query or filters defining the batch
- the requested date range, categories, statuses, and maximum item count
- the intended outcome, such as triage drafts, duplicate review, or approved cleanup
- a private or temporary checkpoint location
- the exact authorization boundary for external actions, if any
- any previously saved checkpoint for this batch

Do not store customer bodies, private communications, credentials, or internal-only
identifiers in this public repository. Keep the checkpoint in a user-approved private
or temporary location and retain only the minimum reference needed to resume.

## Approval model

Reading, triaging, verifying documentation, finding duplicates, and drafting are
non-mutating. Posting a response, changing status, routing, merging, closing,
deleting, or otherwise changing external state requires explicit approval.

Approval may cover one item or a precisely bounded batch, but it must name the
allowed action and target set. A general request to "review" or "clean up" is not
authorization to mutate external state. Deletion is destructive and always requires
clear, item-specific authorization.

## Procedure

### 1. Freeze the batch contract

Record the source query, filters, requested maximum, sort order, intended actions,
and authorization boundary. Fetch the current queue from the live system.

Sort by creation time ascending, with a stable unique reference as the tie breaker.
Process oldest first. Record the fetch time, total visible count, and pagination or
cursor state so a resumed run has a deterministic boundary.

### 2. Load or create the checkpoint

For each item, keep a compact record with:

- stable item reference and source update timestamp
- original category, status, and other state needed to detect drift
- triage status: `pending`, `drafted`, `unchanged`, `approved`, `acted`, `verified`, `drifted`, or `blocked`
- documentation and duplicate evidence references
- proposed action and approval scope
- last verified external state, error, and next cursor

On resume, fetch each unfinished item's current state. If it changed since the
checkpoint, mark it `drifted` and re-triage it before any action. Save progress after
every item so interruption does not force a restart.

### 3. Process one item at a time

For the next oldest unfinished item:

1. Fetch the current post, form fields, category, status, and relevant discussion.
2. Run the installed single-item triage policy on that item.
3. Verify capability and workaround claims against current authoritative product
   documentation and current product knowledge. Do not use an old reply as proof.
4. Search for duplicates by underlying job-to-be-done, not title alone. Check the
   current state of the likely canonical item before proposing a merge or closure.
5. Produce a draft action packet containing the triage object, evidence links,
   duplicate relationship if any, customer-facing response draft, and proposed
   state changes.
6. Mark the item `drafted` and persist the checkpoint.

When evidence is insufficient, propose a question or research step instead of
inventing a capability, roadmap commitment, duplicate, or team owner.

### 4. Apply only approved actions

Compare the draft action packet to the recorded approval. If the action or item falls
outside the approved scope, pause it at `drafted` and request approval.

If the supported conclusion is to make no external change, mark the item `unchanged`
with its evidence and persist the checkpoint. For an approved item, mark it
`approved` and persist before acting. Perform one external mutation at a time, then
mark the item `acted` and persist before verification. Never infer that a successful
click, API response, notification, or automation run proves the final state.

### 5. Verify after every mutation

Immediately re-fetch the item from the live source and confirm the exact expected
result, including the response text, status, routing, duplicate relationship, or
absence after an approved deletion. Record the observed state and timestamp. When
it matches the approved result, mark the item `verified` and persist the checkpoint.

If observed state differs from the approved result, mark the item `blocked`, preserve
the evidence, and do not repeat or escalate the mutation automatically. Continue to
another item only when doing so cannot compound the discrepancy.

### 6. Close the batch

Re-fetch the query after the final item. Reconcile the live remaining count with the
checkpoint and report items added or changed during the run separately from the
frozen batch.

## Output

Provide a compact batch ledger:

| Item | Original state | Triage result | Evidence | Proposed action | Approval | Verified state |
| --- | --- | --- | --- | --- | --- | --- |

Lead with totals for inventoried, drafted, approved, verified, unchanged, drifted,
and blocked items. Include:

- documentation or product-knowledge gaps
- duplicate candidates that still need judgment
- response drafts awaiting approval
- every external change and its live verification result
- the checkpoint location and exact resume point

## Guardrails

- Coordinate the installed single-item triage policy; do not duplicate its classification or scoring rules.
- Never post, delete, merge, close, route, or change status without explicit approval.
- Never treat a browser view, notification, or successful request alone as proof of
  the resulting external state.
- Never bulk-close items based only on age, votes, title similarity, or prior triage.
- Keep customer data and operational identifiers out of public files and outputs.
- Do not promise roadmap delivery or expose internal-only reasoning in a public reply.

## Stopping conditions

The batch is complete when every item inside the frozen boundary is either unchanged
by design or has a current draft, every approved mutation has been verified against
the live source, and the checkpoint matches the final query reconciliation.

Pause with a clear resume point when approval is required, authentication or source
access fails, a required knowledge source is unavailable, evidence is insufficient,
or live state has drifted in a way that changes the proposed action.
