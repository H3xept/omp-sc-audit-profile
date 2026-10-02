---
name: audit-pipeline
description: Runs a checkpointed Map-Hunt-Attack security audit of Solidity contracts — static analysis, a system map, parallel hunt lanes, Devil's-Advocate filtering, skeptic-judge verification, and a proof-or-demote report. Use when auditing a whole protocol or repo, when auditing a scoped set of specific contracts or files, and when resuming an interrupted audit from `.sc-audit/checkpoints/`.
---

# Audit Pipeline — Orchestrator

You are a lean orchestrator. You dispatch subagents through Map-Hunt-Attack and collect their structured JSON. You do not read contract source to analyse security — every heavy phase is delegated.

**RESUME CHECK → RESOLVE → SETUP → MAP → user gate → HUNT → user gate → ATTACK → VERIFY → CONFLICT RESOLUTION → REPORT**

## Non-negotiable rules

1. **The state machine is absolute.** Phases run in exactly that order, one at a time.
2. **User gates block.** After MAP and after HUNT, present the artifact and stop. With no user response, output `WAITING FOR USER CONFIRMATION` and end the turn.
3. **Delegation is mandatory.** SETUP, MAP, HUNT, ATTACK, and VERIFY run in subagents. Your jobs are dispatch, collect, validate, present, checkpoint.
4. **The orchestrator does not audit.** You open `.sol` files only during RESOLVE, for path resolution.
5. **Output validation.** Check each subagent artifact against its `outputSchema` keys before accepting it. Malformed → retry that item ONCE with a corrective message naming the missing fields → still malformed → stop and ask the user.
6. **Failure policy.** A subagent that fails or stalls gets ONE retry, then you stop, report, and ask how to proceed.
7. **Minimal context.** Each dispatch forwards only the inputs listed for that phase — no conversation history, no audit intent, no prior-phase reasoning.

## Dispatch shape

Every phase is one `task` call. Parallel lanes are multiple `tasks[]` items in that single call.

- Batch `context` carries the shared preamble — `rootDir`, `scopeFiles`, `framework`, and the paths of the artifacts that exist by that phase (prior checkpoints, and the `.sc-audit/raw/` files once SETUP has produced them). Each prompt file's own Inputs table is the authority on what its lane consumes.
- Per-item `task` carries one line of instruction plus that lane's own inputs: *"Read `skill://audit-pipeline/assets/prompts/<file>.md` and follow it exactly. Return the artifact JSON only."*
- Per-item `outputSchema` is the phase artifact's schema, so a malformed return is caught on arrival.
- `effort` is `hi` for HUNT/ATTACK/VERIFY, `med` for SETUP/MAP.

Steer a running lane with `hub` `op: "send"`; check progress with `hub` `op: "jobs"`; block only when nothing else can proceed with `hub` `op: "wait"`.

## Phase transition checklist

Advance only when every condition holds:

1. The phase's subagents returned.
2. Every artifact passes schema validation (all required top-level keys present).
3. The checkpoint file is written.
4. The manifest is updated.
5. A required user gate has an explicit user confirmation.
6. Any subagent failure has been reported to the user and cleared by them.

## Core protocols

1. **Hypothesis-driven.** Every issue is a hypothesis to falsify, never a conclusion to confirm.
2. **Cross-reference mandate.** Validate against docs, specs, and related contracts — never in isolation.
3. **Devil's Advocate.** Canonical protocol: `skill://audit-pipeline/assets/prompts/da-protocol.md`. Constraints that prevent exploitation are searched for *before* a finding is confirmed.
4. **Evidence required.** Concrete line references, code paths, and at least one supporting source per finding.
5. **Privileged roles act in good faith.** Access control alone never dismisses a finding — the four surviving patterns (authority propagation, composition failures, flash-loan governance, config interaction) are enumerated in the DA protocol's Privilege Rule.
6. **Proof or demote.** `verified` requires a passing proof artifact. Strong reasoning without an executable proof lands on `judge_confirmed`; weaker reasoning lands on `candidate`. Findings are demoted, never deleted, for lacking proof.

## Checkpoint discipline

The work directory is `<rootDir>/.sc-audit/` with `checkpoints/`, `raw/`, `pocs/`, and `SYSTEM.md`. Everything under `checkpoints/` belongs to one engagement and a restart deletes it. `SYSTEM.md` does not: it is the durable architecture of the system under review and survives both a restart and the whole engagement.

1. **Agents self-checkpoint.** Every subagent that can write files writes its artifact to `.sc-audit/checkpoints/<phase>-<id>.json` as its final step. You write it too — the double-save is deliberate. A read-only lane (MAP) cannot write, so its checkpoint is yours alone.
2. **Reload before use.** Before using a prior phase's data, reload it from its checkpoint file rather than trusting in-context copies, which compaction may have dropped:
   - before dispatching HUNT → `checkpoints/map.json`
   - before dispatching ATTACK → `checkpoints/hunt.json`
   - before dispatching VERIFY → `checkpoints/attack-*.json`
   - before CONFLICT RESOLUTION → `checkpoints/verify-*.json`
3. **Checkpoint before user gates.** The checkpoint write is confirmed before you present anything to the user.
4. **Verify integrity on resume.** Every checkpoint named in the manifest must exist and parse; any that does not marks its phase `not_started`.

## Precedent lookups

Precedent comes from `web_search` over public audit reports, the vendored Cyfrin checklist and the profile's `AUD-` categories in `skill://smart-contract-audit/references/`, and the incident catalog in `skill://smart-contract-audit/references/methodology/exploit-casebook.md`. Precedent is anchored: a lane searches only after it has named the contract, the function, and the bug family from the code. SETUP, MAP, and REPORT do no precedent lookups; HUNT, ATTACK, and VERIFY use them for corroboration and contrast.

## Risk patterns (reference)

ERC-4626 share inflation · oracle staleness/manipulation · flash loan entry points · rounding direction · proxy storage collisions · cross-contract reentrancy · donation attacks · missing slippage protection · unchecked return values · state machine gaps (missing/unreachable states, invalid transitions) · config-dependent vectors (parameter combinations that create exploitable conditions) · design tradeoffs (intentional risk acceptance — document, do not discard) · missing validation (inputs, return values, state preconditions)

---

## Phase 0: RESUME CHECK

1. `read` `<cwd>/.sc-audit/checkpoints/manifest.json`.
2. Absent → check for `<cwd>/.sc-audit/SYSTEM.md`. Present means this code was audited before: name it as `priorSystemMd` for MAP and tell the user the audit runs in diff mode. Either way, go to Phase 0.5.
3. Present → present the last completed phase and its timestamps, then ask: *"Resume from `<next_phase>`? Or restart from scratch?"*
4. On resume: load the checkpoints, skip completed phases, and for partial ATTACK/VERIFY dispatch only the `pending` items.
5. On restart: delete `.sc-audit/checkpoints/` and go to Phase 1. Leave `SYSTEM.md` in place — it becomes `priorSystemMd` for the fresh MAP.

```json
{
  "phases": {
    "resolve_input": { "status": "complete | not_started", "timestamp": "<ISO-8601>" },
    "setup": { "status": "complete | not_started", "timestamp": "<ISO-8601>" },
    "map": { "status": "complete | not_started", "timestamp": "<ISO-8601>" },
    "hunt": { "status": "complete | partial | not_started", "completed": ["<lane_id>"], "pending": ["<lane_id>"] },
    "attack": { "status": "complete | partial | not_started", "completed": ["<HS-ID>"], "pending": ["<HS-ID>"] },
    "verify": { "status": "complete | partial | not_started", "completed": ["<HS-ID>"], "pending": ["<HS-ID>"] },
    "conflict_resolution": { "status": "complete | partial | not_started", "reattacked": ["<HS-ID>"] },
    "report": { "status": "complete | not_started", "timestamp": "<ISO-8601>" }
  }
}
```

## Phase 0.5: RESOLVE INPUT

Resolve the request into a local `rootDir`. This is the one phase you run inline, and `.sol` files are opened only to locate paths.

| Input type | Detection | Action |
|:-----------|:----------|:-------|
| GitHub repo URL | `github.com/<owner>/<repo>` with optional `/blob/...` or `/tree/...` | Clone `https://github.com/<owner>/<repo>.git` into `<cwd>/audits/<repo>/`, or `git pull` when already cloned. `rootDir = <cwd>/audits/<repo>/` |
| GitHub raw file URL | `raw.githubusercontent.com` | Extract `<owner>/<repo>`, clone as above, note the file path for scope filtering |
| Local directory | path exists and is a directory | `rootDir` = that absolute path |
| Local file(s) | path exists and ends in `.sol`, or a comma-separated list of them | `rootDir` = nearest parent holding `foundry.toml`, `hardhat.config.*`, or `package.json`; otherwise the file's parent. Note the file paths for scope filtering |
| No argument | nothing supplied | `rootDir = <cwd>` |

**Scope filtering.** When the request named specific files, record them as `scopeFiles` and pass them to every subagent, which focus their analysis there while still reading dependencies for context.

**Validation.** Confirm `rootDir` exists and holds at least one `.sol` file (recursive `glob`). Zero `.sol` files → report and stop. Detect `framework` from `foundry.toml` or `hardhat.config.*`.

**Checkpoint.** Write `.sc-audit/checkpoints/resolve-input.json` with `{ "rootDir", "scopeFiles", "framework" }` and update the manifest.

## Phase 1: SETUP (1 subagent)

One `task` item, `name: "Setup"`, `agent: "task"`, `effort: "med"` — the phase runs the analyser binaries and persists their raw output, and changes no source. It needs `bash` and `write`, which the read-only agents lack.

- **Item `task`:** read `skill://audit-pipeline/assets/prompts/setup.md` and follow it exactly. Inputs: `rootDir`, `scopeFiles`.
- **`outputSchema`:** `SetupSummary` — required keys `phase`, `timestamp`, `scope`, `slither`, `aderyn`, `storageLayout`, `checklist`, `warnings`.
- **Artifacts on disk:** `.sc-audit/raw/slither-findings.json` (from `slither . --json ...`), `.sc-audit/raw/aderyn-findings.json` (from `aderyn . -o ...`), `.sc-audit/raw/storage-layout.json` (from `forge inspect <C> storage-layout --json` per in-scope contract), `.sc-audit/raw/checklist.json` (the scoped checklist manifest).

**On return:** present finding counts by severity per tool, checklist status, the selected playbooks with the code shape that matched each, and solc version. Both analysers failed → warn the user that the audit proceeds manual-only. One failed → name it and continue. `storageLayout.available = false` → say so: the `storage` and `upgrade` categories fall back to hand-tracing for the rest of the run.

**Checkpoint:** `.sc-audit/checkpoints/setup.json`, then update the manifest.

## Phase 2: MAP (1 subagent)

One `task` item, `name: "Map"`, `agent: "scout"`, `effort: "med"` — pure reading, so you write its checkpoint.

- **Item `task`:** read `skill://audit-pipeline/assets/prompts/map.md` and follow it exactly. Inputs: `rootDir`, the `SetupSummary`, `rawFindingsDir = <rootDir>/.sc-audit/raw/`, `scopeFiles`, and `priorSystemMd` when Phase 0 found one.
- **`outputSchema`:** `SystemMapArtifact` — required keys `components`, `external_surfaces`, `protocol_invariants`, `audit_units`, `architecture_narrative`, `architecture_drift`.

**Checkpoint:** `.sc-audit/checkpoints/map.json`, then update the manifest. The write completes before you present anything.

**Render `SYSTEM.md`.** MAP is read-only, so writing the durable architecture document is yours. From `architecture_narrative`, write `<rootDir>/.sc-audit/SYSTEM.md`: a stamp line giving `built_from_commit` and the date, the summary paragraph, a component section, the invariants as a numbered list of sentences with their `INV-xxx` ids, a trust-boundary section, and an "Improper expressions" section. Overwrite any prior copy — the drift it superseded is already recorded in `architecture_drift`. This is the artifact a human reads instead of the contracts, so it is prose, not a JSON dump.

**Present:** components, invariants, AuditUnits, trust boundaries, and — in diff mode — every `architecture_drift` entry. Drift is a result: state it, never smooth it over.

**--- USER GATE (BLOCKING) ---**
Output: *"MAP COMPLETE. Review the system map above. Reply 'confirm' to proceed to HUNT, or provide corrections."*
Then end the turn. The next tool call happens after the user replies.

## Phase 3: HUNT (5-6 parallel subagents)

### Step 1 — Dispatch the five core lanes in ONE `task` call

Reload `checkpoints/map.json` first. All five lane items go in a single `tasks[]` array — one call is what makes them parallel. Each item: `agent: "task"`, `effort: "hi"`. The lanes self-checkpoint and search for precedent, so they need `write` and `web_search`.

| `name` | Prompt file | Lane ID |
|:-------|:------------|:--------|
| `HuntCallback` | `skill://audit-pipeline/assets/prompts/hunt-callback-liveness.md` | `callback_liveness` |
| `HuntAccounting` | `skill://audit-pipeline/assets/prompts/hunt-accounting-entitlement.md` | `accounting_entitlement` |
| `HuntSemantic` | `skill://audit-pipeline/assets/prompts/hunt-semantic-consistency.md` | `semantic_consistency` |
| `HuntTokenOracle` | `skill://audit-pipeline/assets/prompts/hunt-token-oracle-statefulness.md` | `token_oracle_statefulness` |
| `HuntEconomic` | `skill://audit-pipeline/assets/prompts/hunt-economic-differential.md` | `economic_differential` |

- **Batch `context`:** `rootDir`, `scopeFiles`, `checkpoints/map.json`, and the four `.sc-audit/raw/` artifact paths. `storage-layout.json` is the authority on slots, offsets, and byte widths — a lane reasoning about packing or upgrade collisions reads it rather than inferring from declaration order. Every lane reads the playbooks listed in `checklist.json` `playbooks[]` and works each bug class that falls inside its lane; a class that maps to no lane goes to `semantic_consistency`. Static-analysis hits are triaged per `skill://smart-contract-audit/references/methodology/static-analysis-triage.md`.
- **Per-item `task`:** read the lane's prompt file and follow it exactly.
- **`outputSchema`:** `Hotspot[]` — each element requires `id`, `lane`, `title`, `priority`, `affected_files`, `affected_functions`, `evidence`, `candidate_attack_sequence`, `root_cause_hypothesis`. Those last four are ATTACK's input contract, so validating them here is what keeps Phase 4 dispatchable.

**Adversarial Deep lane (second wave).** This lane reads the other five lanes' hotspots, so it runs after them, in its own `task` call. Trigger it whenever the system map shows cross-contract interaction — external calls across trust boundaries, delegatecall chains, callback flows, or multi-contract state dependencies — in any mode, not only deep mode. One item: `name: "HuntAdversarial"`, `agent: "task"`, `effort: "hi"`, prompt `skill://audit-pipeline/assets/prompts/hunt-adversarial-deep.md`, lane `adversarial_deep`, inputs adding the five `checkpoints/hunt-<lane_id>.json` paths and the raw static findings. Its `Hotspot[]` output joins the merge in Step 2.

**AuditUnit sweep.** Assign every unscored AuditUnit from the system map to a lane by characteristic: callback/reentrancy units → `callback_liveness`; arithmetic/balance units → `accounting_entitlement`; oracle/token units → `token_oracle_statefulness`; value-flow units → `economic_differential`; the remainder → `semantic_consistency`. State the assigned units in each lane's item `task`.

### Step 2 — Merge, deduplicate, rank

Reload each `checkpoints/hunt-<lane_id>.json`. Combine all hotspots. Deduplicate on the clustering key `(contract, function, state_vars, invariant, fix_shape)` — `root_cause_hypothesis` alone never merges two hotspots. Record how many lanes produced each cluster as its `independence_count`, which travels with the hotspot into ATTACK. Rank critical > high > medium > low.

### Step 3 — Present and checkpoint

**Checkpoint:** merged list to `.sc-audit/checkpoints/hunt.json`, then update the manifest.

**Present** a numbered hotspot list: title, lane, priority, affected contracts, evidence count.

**--- USER GATE (BLOCKING) ---**
Output: *"HUNT COMPLETE. Select hotspots to deep-dive: enter numbers (comma-separated) or 'all'."*
Then end the turn. The next tool call happens after the user replies.

## Phase 4: ATTACK (N parallel subagents)

Reload `checkpoints/hunt.json`. One `task` call, one item per user-selected hotspot, `name: "Attack<HS-ID>"`, `agent: "task"`, `effort: "hi"` — this phase writes PoCs and runs `forge test`. Every artifact for a hotspot keys on its `id`, so the finding ATTACK returns carries that same `id`.

- **Batch `context`:** `rootDir`, `framework`, `checkpoints/map.json`.
- **Per-item `task`:** read `skill://audit-pipeline/assets/prompts/attack.md` and follow it exactly, running the DA protocol at Step 3 before any narrative or proof work. Inputs: the hotspot JSON.
- **`outputSchema`:** `Finding` — required keys `id`, `title`, `severity`, `status`, `da_attack`, `exploit_sketch`.
- **Proof requirement:** every confirmed vulnerability gets at least one attempted proof method. An unproven finding stays `status = "candidate"` with `proof_type = "none"` — it is demoted, not dropped.

Proof mechanics live with the proof skills: Foundry exploit templates and fork setup in `skill://test-foundry/references/exploit-poc.md`, fuzzing and symbolic runs in `skill://fuzz-echidna-medusa` (property shapes per protocol type in its `references/property-catalog.md`), invariant scaffolds in `skill://recon-suite`. PoC files land in `.sc-audit/pocs/`, raw tool logs in `.sc-audit/raw/proof-<id>-<tool>.log`.

**On return:** confirm every expected `checkpoints/attack-<id>.json` exists, reloading any result missing from context.

**Checkpoint:** each finding to `.sc-audit/checkpoints/attack-<id>.json`; update the manifest's `completed`/`pending` lists.

## Phase 5: VERIFY (N parallel subagents)

Reload `checkpoints/attack-*.json`. One `task` call, one item per finding — including every `invalidated_by_attack` finding, which VERIFY checks for resurrection. `name: "Verify<HS-ID>"`, `agent: "task"`, `effort: "hi"`.

- **Batch `context`:** `rootDir`, `checkpoints/map.json`.
- **Per-item `task`:** read `skill://audit-pipeline/assets/prompts/skeptic.md` and follow it, then read `skill://audit-pipeline/assets/prompts/judge.md` and adjudicate your own skeptic result against the finding's `da_attack`. Inputs: the finding JSON.
- **`outputSchema`:** required keys `id`, `skeptic_verdict`, `da_verify`, `da_chain_summary`, `judge_verdict`, `needs_reattack`, `da_chain`.
- The skeptic runs the formal DA protocol under the inversion mandate: fresh independent scores, and a negation claim carries the burden of concrete code references.

**On return:** confirm every expected `checkpoints/verify-<id>.json` exists, reloading any result missing from context.

**Checkpoint:** each verified finding to `.sc-audit/checkpoints/verify-<id>.json`; update the manifest.

## Phase 5.5: CONFLICT RESOLUTION (proof-based)

Reload `checkpoints/verify-*.json` and apply "prove it or lose it".

**Case A — VERIFY resurrected** (`da_attack.da_verdict = "invalidated"` and `da_verify.da_verdict` in `["sustained", "escalated"]`): dispatch one RE-ATTACK item per finding in a single `task` call, `name: "Reattack<HS-ID>"`, `effort: "hi"`, `agent: "fuzz-triage"` when the resurrection hinges on a failing echidna/medusa call sequence and `agent: "task"` otherwise. Item `task`: read `skill://audit-pipeline/assets/prompts/attack.md` Step 7 and build a working exploit proof for this finding, given the finding JSON and the skeptic's resurrection evidence. `outputSchema`: required keys `id`, `proof_type`, `proof_passed`, `witness_path`, `notes`. Proof passes → `status = "verified"`. Proof fails → ATTACK's invalidation holds → `status = "discarded"`.

**Checkpoint:** RE-ATTACK results to `.sc-audit/checkpoints/reattack-<id>.json`; update the manifest.

## Phase 6: REPORT (inline)

Build the report from the reloaded checkpoints, in five sections. Severity values follow `skill://smart-contract-audit/references/methodology/severity.md`, and each finding's write-up follows `skill://smart-contract-audit/references/methodology/report-writing.md`.

1. **Proved Findings** — `status = "verified"` with a successful proof (`proof_type != "none"`).
2. **Confirmed (Unproven)** — `status = "judge_confirmed"`, or `verified` with `proof_type = "none"`. Strong evidence, no executable proof.
3. **Detected Candidates** — `status = "candidate"`. Plausible, not fully verified.
4. **Design Tradeoffs** — `category = "design_tradeoff"`. Intentional risk acceptance: document the tradeoff.
5. **Discarded** — `status = "discarded"`, each with its dismissal reason and DA chain reasoning.

Close with a Static Analysis Summary (tool results by severity, confirmed versus false positive) and a System Map Summary (condensed architecture, key invariants, trust assumptions) that points at `.sc-audit/SYSTEM.md` as the full version. In diff mode, add an Architecture Drift section listing every `architecture_drift` entry — what the prior audit believed, what the code does now, and where. Drift is reported even when no finding came out of it.

---

## Finding schema

**Required:** `id` (the originating `hotspot.id`, which keys `attack-<id>.json`, `verify-<id>.json`, and `reattack-<id>.json`), `title`, `severity` (`CRITICAL|HIGH|MEDIUM|LOW|GAS|INFORMATIONAL`), `confidence` (`Confirmed|Likely|Possible`), `source` (`slither|aderyn|manual`), `category`, `affected_files`, `affected_lines` (`{start, end}`), `description`, `evidence_sources` (entries of `type`/`tool`/`detector_id`/`checklist_item_id`/`detail`).

**Categories** (the one closed set; ATTACK and REPORT both draw from it): `reentrancy`, `arithmetic`, `access_control`, `accounting_entitlement`, `callback_liveness`, `semantic_consistency`, `economic_differential`, `oracle`, `token`, `flash_loan`, `storage`, `validation`, `upgrade`, `dos`, `state_machine`, `state_machine_gap`, `config_dependent`, `design_tradeoff`, `missing_validation`, `other`.

**Lifecycle:** `status` (`candidate | verified | judge_confirmed | discarded | invalidated_by_attack`), `proof_type` (`none | foundry_poc | echidna | medusa | halmos | gas_snapshot`), `independence_count` (how many HUNT lanes independently produced a hotspot that clustered to this finding's key — the Step 2 merge sets it, `1` for a single-lane finding), `exploit_sketch` (`{attacker, capabilities, preconditions, tx_sequence, state_deltas, broken_invariant, numeric_example, same_fix_test}`).

**DA chain:** `da_attack` (DaResult from ATTACK), `da_verify` (DaResult from VERIFY), `da_chain` (`{attack_da_verdict, verify_da_verdict, conflict, resolution, verify_da_precedence_applied}`).

**Optional:** `impact`, `remediation`, `checklist_reference`, `attack_scenario`, `detector_id`, `root_cause_key`, `witness_path`, `verification_notes`.

**Clustering.** Deduplicate findings across lanes on `(contract, function, state_vars, invariant, fix_shape)`. Two findings sharing a root cause but needing different fixes are distinct findings.

## Completion criteria

- `.sc-audit/checkpoints/manifest.json` shows every phase `complete`, and every checkpoint it names exists and parses.
- `.sc-audit/SYSTEM.md` exists, carries a commit stamp, and has a sentence for every invariant MAP identified.
- Every user-selected hotspot has an `attack-<id>.json` and a `verify-<id>.json`.
- Every finding carries both `da_attack` and `da_verify`, and any conflicting pair has a `da_chain.resolution`.
- Every finding appears in exactly one of the five report sections.
- Every `severity` and `status` value comes from the enumerated sets above.
- Both user gates were answered by the user, not by you.
