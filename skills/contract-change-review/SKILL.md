---
name: contract-change-review
description: "Review exact versions of a contract or amendment, extract and classify changes, find placeholders and execution blockers, separate legal from commercial decisions, and draft a response. Use for redlines, vendor or customer paper, amendments, renewals, or signature-readiness checks."
---

# Contract Change Review

Produce an evidence-backed comparison between exact contract versions or a readiness review of one exact document, plus a concise response draft when requested. This workflow is informational and operational support, not legal advice. A licensed attorney in the relevant jurisdiction must review legal conclusions and final language before execution.

Never sign, send, accept, reject, or otherwise bind a party. Drafting a response is not authorization to deliver it.

## Stable Inputs

Obtain:

- The review mode: `comparison` for a redline/change review or `readiness-only` for a single-document completeness and execution check.
- In comparison mode, the exact baseline and proposed documents, including filenames, dates, versions, or hashes. In readiness-only mode, the exact current document.
- All incorporated exhibits, schedules, order forms, policies, and referenced terms.
- The business context, relationship, and intended transaction.
- The governing jurisdiction if known.
- Approved commercial posture, non-negotiables, prior decisions, and response deadline if available.
- The desired output: review only, proposed language, response draft, or execution-readiness check.

Do not infer missing terms from a previous negotiation or similarly named file. If a document required by the selected mode or an incorporated document is unavailable, flag the limitation before analyzing substance.

## Confidentiality and Evidence Rules

- Work from the current source documents, not summaries or screenshots when originals are available.
- Keep private contracts, communications, counterpart details, and negotiation positions out of public repositories, logs, and unapproved external services.
- Quote only the minimum text needed to support a finding.
- Separate document facts, business preferences, legal questions, and recommendations.
- Preserve tracked changes, comments, formatting-only changes, and OCR uncertainty as distinct evidence.

## Procedure

### 1. Establish Document Identity

- Record filenames, supplied version labels, modification dates, page counts, and hashes when practical.
- Confirm the review mode. For comparison mode, confirm which document is baseline and which is proposed; for readiness-only mode, identify the single authoritative document.
- Inventory attachments and terms incorporated by reference; note any missing or inaccessible item.
- Determine whether the files contain tracked changes, comments, hidden text, scanned pages, or electronic-signature fields.
- If OCR is required, identify low-confidence passages and verify material clauses visually.

Do not begin clause classification until the selected mode and document identity are unambiguous.

### 2. Extract the Complete Change Set

- In readiness-only mode, record that no baseline comparison was requested, skip the remaining comparison steps in this section, and continue to step 3.
- In comparison mode, use an appropriate document comparison or redline, then verify material changes against the rendered originals.
- Capture additions, deletions, replacements, moved text, comment-only requests, changed tables, and changes in exhibits or signature blocks.
- Check defined terms, cross-references, numbering, precedence clauses, and references to external policies after edits.
- Distinguish formatting noise from semantic changes. Do not rely on visual redline color alone.
- Assign every material change a stable clause, section, page, or exhibit reference.

### 3. Check Completeness and Execution Readiness

Inventory:

- Blank fields, bracketed text, drafting notes, unresolved comments, and placeholder dates.
- Legal names, entity types, addresses, notice details, effective dates, terms, and signature authority.
- Missing exhibits, conflicting order-of-precedence language, broken cross-references, undefined terms, and inconsistent amounts or dates.
- Signature blocks, counterpart mechanics, required approvals, and any conditions that must occur before execution.

An otherwise acceptable contract is not execution-ready while material placeholders or incorporated documents remain unresolved.

### 4. Separate Legal and Commercial Issues

Classify the primary owner of each issue:

- **Legal**: liability, indemnity, IP, confidentiality, privacy, data protection, security obligations, compliance, warranties, governing law, dispute resolution, termination rights, and remedies.
- **Commercial**: pricing, payment, scope, term, renewal, service levels, implementation, support, volume, credits, publicity, and operating commitments.
- **Both**: a clause whose legal allocation changes a material commercial outcome. Name both owners rather than forcing one category.

Do not treat a business preference as a legal requirement or a legal risk as an approved commercial concession.

### 5. Classify Each Material Finding

In comparison mode, each item is a material change. In readiness-only mode, each
item is a clause risk, ambiguity, inconsistency, placeholder, or execution blocker;
do not describe it as a change without a baseline.

Use exactly one disposition:

- **Must fix**: creates an unapproved or material legal, financial, security, operational, or execution risk; contradicts an agreed position; or omits a necessary fact.
- **Acceptable**: is supported by the approved posture and leaves no material unresolved risk within the available evidence.
- **Clarify**: is ambiguous, fact-dependent, outside known authority, or requires a legal or business-owner decision.

For each item, explain the practical effect, the evidence, the decision owner, and the recommended response or language. Mark legal judgment calls for counsel even when a commercial recommendation is clear.

### 6. Test Downstream Obligations

- Translate material clauses into concrete duties, deadlines, systems, costs, dependencies, and internal owners.
- Check that the organization can actually meet security, reporting, support, insurance, deletion, audit, or notice commitments.
- Identify terms that conflict with referenced policies, product behavior, existing commitments, or operational capability.
- Ask the smallest decision question needed when authority or facts are missing; do not silently harmonize conflicts.

### 7. Draft the Response When Requested

- Skip this step when the requested output is review-only.
- Lead with the recommended disposition and the smallest set of requested changes.
- Reference clause numbers and explain the business or operational reason in plain language.
- Keep legal and commercial asks distinguishable.
- Match the user's established voice when evidence is available: direct, concise, and specific. Do not invent tone from private communications that were not provided.
- Include alternative wording only when the tradeoff could change the decision.
- Clearly label the response as a draft pending user and, where applicable, counsel approval.

## Output Schema

Return:

1. **Executive recommendation**: proceed, proceed after changes, hold for clarification, or not execution-ready; include the reason.
2. **Document identity**: review mode, authoritative document or baseline/proposed versions, attachments reviewed, comparison method or `not applicable`, and limitations.
3. **Material findings register**: changes and practical effects in comparison mode; clause risks or readiness findings in readiness-only mode.

   | Clause/page | Change or finding and practical effect | Legal/commercial owner | Disposition | Recommended response |
   |---|---|---|---|---|

4. **Placeholders and execution blockers**:

   | Location | Missing or inconsistent item | Owner | Required resolution |
   |---|---|---|---|

5. **Decisions and questions**: unresolved business choices, factual questions, and counsel questions kept separate.
6. **Draft response, when requested**: ready for user editing, not sending.
7. **Counsel review flags**: jurisdiction-specific issues and clauses requiring licensed legal review.

## Stop Conditions

A review is complete only when:

- The exact document set required by the selected mode is identified.
- In comparison mode, every material textual and incorporated-document change is accounted for and classified; in readiness-only mode, the absence of a baseline is explicit and no change claim is made.
- All placeholders, missing exhibits, cross-reference defects, and signature-readiness blockers are inventoried.
- Legal and commercial owners are separated, and unknown authority is explicit.
- Any requested response draft reflects the findings and is clearly held for approval.

Stop as blocked when a document required by the selected mode is missing, a material annex is unavailable, OCR prevents reliable reading, versions changed during review, or the next step would require legal judgment or external action beyond the user's authorization. State the exact missing evidence or approval needed.
