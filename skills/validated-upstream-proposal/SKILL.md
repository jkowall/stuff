---
name: validated-upstream-proposal
description: Turn technical feedback or a feature request into an evidence-backed upstream proposal grounded in the current implementation, documentation, issues, and pull requests. Use when a proposed API, behavior, integration, metric, protocol, or architecture change needs a scoped design, compatibility proof, breaking-change disclosure, and reviewable pull-request plan.
license: Apache-2.0
metadata:
  generated: "2026-08-03"
  output: publish-ready technical proposal or evidence blocker
---

# Validated upstream proposal

Produce the smallest technically credible proposal that solves the underlying job.
Validate current behavior before specifying new behavior. A polished proposal built
on an incorrect premise is not complete.

## Inputs

Collect:

- the original feedback, problem statement, or observed failure
- the target product, repository, component, and intended upstream venue
- source links, reproductions, examples, or prior discussion
- known users and the job they need to complete
- compatibility contracts and operational constraints already identified
- the requested output depth: recommendation, issue draft, design proposal, or PR plan

If the target or current implementation cannot be identified, stop and ask for the
missing scope rather than drafting a generic design.

## Evidence rules

- Inspect the real current implementation and documentation before relying on memory
  or a summary.
- Use exact versions, commits, release numbers, or as-of dates when behavior can drift.
- Search current and closed issues, pull requests, discussions, release notes, and
  relevant history before claiming the proposal is new.
- Treat tests as behavioral evidence, not merely implementation detail.
- Separate confirmed facts, reasonable inferences, open questions, and proposed
  choices in every major section.
- Do not invent adoption, customer demand, performance results, or compatibility.

## Procedure

### 1. Extract the job-to-be-done

Rewrite the request as:

> When **situation**, the user needs to **job**, so they can **outcome**.

Separate the user's proposed mechanism from the underlying job. Record affected
users, severity, frequency, current workaround, and the cost of doing nothing only
when evidence supports them.

### 2. Establish current behavior

Inspect and cite:

- implementation paths and execution flow
- public API, configuration, schema, protocol, or metric contract
- official documentation and examples
- tests that lock in current behavior
- released behavior when it differs from the development branch
- existing observability, failure handling, and operational assumptions

Build a short evidence table with source, exact version or date, finding, and proposal
impact. If the request is already supported, recommend documentation or enablement
before a code change.

### 3. Search for prior art and collisions

Search open and closed issues, PRs, discussions, changelogs, adjacent components,
and relevant upstream standards. Note duplicates, abandoned approaches, reviewer
concerns, naming collisions, and active work. Verify current state rather than relying
on labels or an old notification.

### 4. Evaluate options

Compare at least these where applicable:

- use the current capability or workaround
- documentation or example improvement
- configuration-only change
- minimal general-purpose primitive
- broader architectural change
- do nothing

Assess job coverage, product fit, implementation and forever-cost, usability,
operational risk, and compatibility. Recommend one option and explain why the others
do not meet the evidence.

### 5. Define scope and non-goals

State the affected components, users, supported cases, and success signal. List
explicit non-goals to prevent the proposal from absorbing adjacent workflows or
speculative future needs.

### 6. Specify the change

Describe:

- proposed behavior and user-facing contract
- control and data flow
- configuration, API, schema, protocol, or metric changes
- validation and error semantics
- concurrency, ordering, retry, and partial-failure behavior where relevant
- security, privacy, performance, and observability implications
- rollout, migration, rollback, and documentation changes

Use pseudocode or interface sketches only when they make the contract more precise.
Do not present implementation detail as decided when reviewers still need to choose.

### 7. Define compatibility proof

List the invariants that must remain true and the evidence that will prove each one.
Use the strongest applicable checks, such as:

- golden or byte-for-byte output comparison
- existing API and protocol conformance tests
- backward and forward compatibility fixtures
- old configuration against new code
- upgrade, downgrade, and rollback checks
- unchanged metrics, labels, alerts, or documented error behavior
- performance or resource bounds measured against a stated baseline

If compatibility cannot be proved, label the uncertainty and treat it as a design
blocker or breaking change rather than assuming safety.

### 8. Disclose breaking and operational changes

Explicitly assess compile-time, runtime, configuration, schema, storage, protocol,
metric, alerting, performance, security, and support impacts. A technically compatible
endpoint can still be operationally breaking. State affected users, detection,
migration, rollback, and release-note requirements for every material change.

### 9. Slice the implementation

Create a sequence of independently reviewable PRs. For each slice, state:

- purpose and dependency
- files or components likely affected
- user-visible behavior
- focused validation
- compatibility evidence
- rollback or safe stopping point

Prefer preparatory tests and observability before behavior changes. Avoid a stacked
plan whose early PRs leave the target branch unsafe or misleading.

### 10. Prepare upstream review

Re-check live issues and PRs immediately before finalizing. List the specific reviewer
questions that could change scope or contract. Draft a concise issue or proposal with
evidence links, alternatives, compatibility proof, and disclosed risks.

Do not open an issue, publish a proposal, send messages, or create a PR without
explicit approval.

## Output

Lead with the recommendation. Then provide:

1. job-to-be-done and validated problem evidence
2. current-behavior and prior-art evidence table
3. options considered and rationale
4. goals, non-goals, and proposed contract
5. compatibility invariants and proof plan
6. breaking and operational change disclosure
7. ordered PR slices with validation and rollback points
8. reviewer questions, unresolved evidence, and publish-ready proposal text

Label statements as `confirmed`, `inference`, `proposal`, or `open question` where
their status could otherwise be confused.

## Guardrails

- Never design from feedback alone when current implementation evidence is available.
- Never convert one requested solution into a broad product commitment without
  validating the underlying job and generality.
- Never hide a metrics, alerting, protocol, migration, or support change under a
  compatibility claim.
- Never claim tests passed unless they were run against the stated version.
- Keep credentials, customer data, private communications, and confidential examples
  out of public proposals.
- Preserve repository-local review, test, contribution, and release rules.

## Stopping conditions

The work is complete when the proposal is traceable to current implementation and
problem evidence, scope and non-goals are explicit, compatibility and breaking-change
handling are testable, and the PR plan gives reviewers safe decision points.

Stop with an evidence blocker when current behavior cannot be verified, prior work
cannot be searched, a required compatibility invariant lacks a feasible proof, or an
upstream decision is needed before the contract can be specified honestly.
