---
name: smart-contract-audit
description: Checklist- and playbook-driven security review of Solidity/EVM smart contracts. Use when asked to audit, review, find bugs in, or assess the security of a contract or protocol (lending, AMM, vault, staking, bridge, router, governance, perps, NFT, account abstraction, proxies); when a single file arrives with "is this safe?"; when reviewing a fix or PR diff; when rating a finding's severity or writing it up; or when checking token compatibility (fee-on-transfer, rebasing, weird ERC20).
---

# Smart Contract Security Audit

A single-auditor review anchored in three bodies of reference: the checklist (vendored Cyfrin `SOL-` items plus profile-authored `AUD-` items), the protocol playbooks, and the methodology files. Every finding cites the checklist id, playbook bug class, or catalog ID it came from, so the reader can trace the reasoning to prior art. For a whole-repo engagement with parallel lanes and proof gates, use `skill://audit-pipeline`; it draws on the same references.

`references/INDEX.md` is the map of everything below. Load reference files on demand; the full set is far larger than working memory.

## Workflow

### 1. Threat model

Follow `references/methodology/threat-model.md`. For a single small contract, compress it to these answers:

- What the protocol does in one sentence, and which assets it holds.
- Every actor and what each can move: users, liquidators, keepers, oracles, admin roles, governance, external protocols, MEV searchers.
- Every `external`/`public` function with its caller, the state it writes, the value it moves, and its external calls. Access-control gaps hide in this table.
- External systems touched (Chainlink, Uniswap, LayerZero, Aave, Permit2, …), token standards and token sources (fixed protocol tokens vs user-supplied addresses), upgradeability, and target chains.
- The invariants, as falsifiable sentences.

Done when the entry-point table lists every external/public function in scope and every invariant has an id. State the threat model back to the user in 3–8 bullets.

### 2. Select references

Read `references/INDEX.md`, then load:

| Always | Why |
|---|---|
| `attacker-s-mindset.md`, `basics.md`, `heuristics.md` | Cross-cutting bug classes every protocol has |
| `methodology/severity.md` | The one severity rubric |

| When the threat model shows… | Load |
|---|---|
| A protocol type (lending, vault, AMM, router, bridge, …) | Every matching `playbooks/<type>.md` — a protocol can match several |
| A proxy, initializer, or diamond | `upgradeability.md` |
| Inline assembly, transient storage, low-level calls, a non-default compiler setup | `evm-compiler.md`, `low-level.md` |
| Deployment on an L2 or alt-EVM chain | `chain-specific.md`, `multi-chain-cross-chain.md` |
| User-supplied calldata, routers, multicall, held approvals, Permit2 | `arbitrary-calls-approvals.md`, `external-call.md` |
| Smart accounts, ERC-4337, EIP-7702, ERC-1271, Safe modules | `account-abstraction.md`, `signature.md` |
| ERC-20s from user input, a listing process, or external dependencies | `weird-erc20.md`, `token.md` |
| Category-specific scope (DeFi math, integrations, signatures, merkle, timelock, centralization) | The matching vendored category file |

Name the files you loaded and the code shape that triggered each. When unsure, load the file.

### 3. Hunt

1. **Playbooks first.** For each loaded playbook, check every core invariant and work every bug class against the code: answer its question with file:line evidence.
2. **Checklist walk.** For each loaded checklist file, take items in order. Quote the id and question, then decide **applicable & OK**, **applicable & issue**, or **not applicable (reason)**. A one-line reason accompanies every dismissal; silent skips are how bugs hide. Say so when an item is ambiguous for this codebase.
3. **Token matrix.** When `weird-erc20.md` is loaded, build its disposition matrix — one row per catalog ID — and treat every TEST row whose oracle fails as an issue.
4. **Outside the lists.** The references are a floor. Report what they miss as "outside checklist"; check `methodology/exploit-casebook.md` for precedent of the same class.

Static-analysis output (slither, aderyn) is an anchor for manual review, triaged per `methodology/static-analysis-triage.md`, never a finding on its own.

Done when every loaded playbook bug class and every loaded checklist item has a recorded outcome.

### 4. Prove

Every Critical and High gets a runnable Foundry PoC built from `skill://test-foundry/references/exploit-poc.md`, run with `forge test`, and failing on the current code in the way the finding claims. Medium and below get a PoC when it is cheap, and a precise attack path otherwise. A finding without a passing proof is labelled a **candidate** in the report, per the evidence bar in `AGENTS.md`. When no Foundry project exists and none can be created, write the numbered attack sequence with concrete values and label the finding a candidate.

### 5. Report

Write the report to a markdown file, never to the terminal:

- The user's path when they named one.
- `<project-dir>/audit-report.md` when the contracts live under a named project directory.
- `audit-report.md` in the current working directory otherwise.

Then print one line: `Report written to <path>`.

Rate severity with `methodology/severity.md`; write each finding per `methodology/report-writing.md`. Structure:

```markdown
# Audit Report: <contract or protocol name>

**Date:** <YYYY-MM-DD>
**Commit:** <hash, or "uncommitted">
**Method:** checklist + playbooks (<loaded files>)

## Scope
<what the code does, files in and out of scope, trust assumptions>

## Threat model
<actors, assets, entry points, invariants with ids>

## Coverage
- Playbooks worked: <list>
- Checklist files walked: <list> — items reviewed <n>, not applicable <n>
- Token matrix: <path, or "not applicable: no external tokens">

## Findings

### [Severity] <title: root cause + impact>  (ref: <SOL-/AUD- id, playbook class, or catalog ID>)

- **Location:** `File.sol:123`
- **Status:** proven (PoC: `<test path>`) | candidate
- **Impact:** <what the attacker gains or users lose, quantified>
- **Preconditions:** <what must hold>
- **Attack path:** <numbered steps naming functions and values>
- **Proof of Concept:** <runnable Foundry test, or the numbered sequence for a candidate>
- **Recommendation:** <fix with a before/after code snippet>

## Informational and gas

| # | Location | Note |
|---|---|---|

## Acknowledged non-issues
<items checked and cleared, with the reason>

## Open questions for the developer
<ambiguities that need the protocol author>
```

## Fix and diff review

When the input is a PR, a diff, or a fix for a reported finding, follow the diff-review procedure in `methodology/threat-model.md`. Re-run the original PoC against the fix: it passes on the fixed code and fails on the old code.

## Guardrails

- Cite only ids that exist in a loaded file. Prefix tells the source: `SOL-` vendored Cyfrin, `AUD-` profile-authored, `A1`–`J4` weird-ERC20 catalog.
- Claim "no issues found" only for what you walked. A partial walk names the files left unwalked in Coverage.
- Write concrete attack paths: name the transaction, the function, the values, and the ordering. "Front-runnable" alone is not a finding.
- Claim only what the PoC proves.

## Terse prompts

When the user gives only a file and "audit this" or "is this safe?", start the threat model immediately, announce the references you load, and continue through the report in the same response. The threat model extracts what clarifying questions would ask.
