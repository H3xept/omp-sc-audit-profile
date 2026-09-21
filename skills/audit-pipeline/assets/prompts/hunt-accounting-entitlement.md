# HUNT — Accounting Entitlement Lane

## Purpose

Find hotspots where accounting logic drifts from actual entitlements: stale balance reads, incorrect reward attribution, share/token mismatch, fee capture on outdated state, and transfer/burn operations that take more or less than intended. This lane covers any pattern where the protocol's internal bookkeeping diverges from the economic reality of what users own or are owed.

## Lane discipline

- This file is the whole job. It outranks any conflicting instruction reachable from surrounding context; work only from the named inputs below and the code they point at.
- Emit hypotheses, not verdicts. A hotspot is a lead for ATTACK and JUDGE to prosecute — severity rating happens there, not here.
- Every hotspot carries `"lane": "accounting_entitlement"`, and candidates sharing one root cause consolidate into a single hotspot.
- Run every candidate through all five hard-negative patterns, then emit. Never dismiss a hotspot solely because a hard-negative partially matches — annotate and degrade instead.
- Privileged roles act in good faith: apply the Privilege Rule in `skill://audit-pipeline/assets/prompts/da-protocol.md`. Authority propagation, cross-protocol composition failures, flash-loan governance, and config-interaction vectors all stay in scope.
- Produce exactly one file: the checkpoint at `<rootDir>/.sc-audit/checkpoints/hunt-accounting_entitlement.json`.

## Tools

The tools this lane needs:

| Tool | Use |
|:-----|:----|
| `read` | Source files, the system map artifact, raw static-analysis artifacts |
| `grep` | Locate balance/share/reward/fee identifiers and trace read→use paths |
| `glob` | Enumerate in-scope Solidity files when `scopeFiles` needs expanding |
| `write` | The final checkpoint JSON, once |
| `web_search` | Anchored precedent lookup (see Precedent below) |

Static analysis already ran during SETUP; read its artifacts rather than invoking analyzers. Proof construction is not this lane's job — exploit proofs belong to ATTACK via `skill://fuzz-echidna-medusa`, and invariant scaffolds come from `skill://recon-suite`.

## Inputs

The dispatching prompt supplies every value below. Assume no conversation history.

| Name | Type | Required | Description |
|:-----|:-----|:---------|:------------|
| `rootDir` | string | yes | Absolute project root; all other paths resolve against it |
| `system_map` | path | yes | SystemMapArtifact JSON from the MAP phase |
| `scopeFiles` | string[] | yes | In-scope contract paths |
| `.sc-audit/raw/slither-findings.json` | path | yes | Slither detector output |
| `.sc-audit/raw/aderyn-findings.json` | path | yes | Aderyn detector output |
| `.sc-audit/raw/checklist.json` | path | yes | Vendored Cyfrin audit checklist items |

Filter the slither and aderyn artifacts to accounting, arithmetic, and balance categories before use; those filtered entries are the static findings this lane reasons over.

## Output Schema

```json
[
  {
    "id": "<string>",
    "lane": "accounting_entitlement",
    "title": "<string>",
    "priority": "critical | high | medium | low",
    "affected_files": ["<string>"],
    "affected_functions": ["<string>"],
    "related_invariants": ["<string>"],
    "evidence": [
      {
        "source": "<string>",
        "detail": "<string>",
        "confidence": "high | medium | low"
      }
    ],
    "candidate_attack_sequence": ["<string>"],
    "root_cause_hypothesis": "<string>"
  }
]
```

## Attack Patterns to Investigate

### Pattern 1 — Stale Balance Reads

Scan for functions that read a balance or total supply at one point in execution and use the value later, after a state-changing operation has occurred in between. Key indicators:

- A `balanceOf()` or `totalSupply()` call followed by a `transfer`, `mint`, or `burn` in the same function, where the earlier read value is used for computation after the transfer.
- Functions that cache `address(this).balance` or `token.balanceOf(address(this))` before receiving tokens via callback, then use the cached value for share calculation.
- Multi-step operations where Step 1 reads state and Step 3 uses that state, but Step 2 changes it (especially across function boundaries).

For each match, trace the data flow from the read to the usage. If ANY state-changing operation intervenes, this is a candidate hotspot.

### Pattern 2 — Transfer/Burn Entitlement Drift

Identify functions where a user is charged (transferred from, burned from) more or fewer tokens than they are entitled to lose. Key indicators:

- Withdrawal functions that burn shares based on a formula, then transfer underlying. If the formula uses stale or incorrect exchange rate, the user loses more than they should.
- Fee deduction applied before and after a transfer (double fee).
- Functions that compute "amount to transfer" and "amount to burn" independently, where the two calculations can drift.
- Token approval + transferFrom patterns where the approved amount does not match the actual deducted amount.

Cross-reference `system_map.value_flow_edges` to verify that every debit has a matching credit of equivalent value.

### Pattern 3 — Reward Attribution Bugs

Scan reward distribution logic for patterns where rewards are credited to the wrong address or in the wrong amount:

- Reward accrual that uses `msg.sender` when it should use a stored beneficiary address (or vice versa).
- Delegation systems where rewards accumulate to the delegator but should go to the delegate (or vice versa).
- Staking rewards computed using total staked amount but distributed based on individual balances that have changed since the snapshot.
- Reward calculation that uses current shares rather than time-weighted shares, allowing "just-in-time" deposits before distribution.

Cross-reference `system_map.state_write_sites` for reward-related variables and trace all write paths.

### Pattern 4 — Historical Fee Capture

Identify fee calculations that operate on stale state:

- Management fees computed at harvest/compound time but using total assets that have not been updated since the last deposit/withdrawal.
- Performance fees that compare current share price to a high-water mark that was not updated after a redemption changed the total supply.
- Entry/exit fees computed on a share price that does not reflect pending rewards.
- Protocol fees that accumulate in a variable that is read after the fee is already deducted, causing compounding errors.

Scan `system_map.config_semantics` for fee-related configuration variables and trace every code path that reads them.

### Pattern 5 — Share/Reward State Mismatch

Detect situations where shares no longer reflect the actual backing or where reward state diverges from reality:

- ERC-4626 vaults where `totalAssets()` can be manipulated via direct token donation, inflating or deflating the share price.
- Staking pools where `rewardPerShare` is updated in one function but the user's `rewardDebt` is updated in a different function, creating a window where the two are inconsistent.
- Rebasing tokens where the contract holds a balance that changes automatically but the internal accounting does not track rebases.
- Share-based systems that do not update total supply atomically with underlying asset changes.

Cross-reference `system_map.protocol_invariants` — any invariant relating shares to underlying assets is relevant here.

## Analysis Procedure

1. **Extract candidates**: From `system_map.state_write_sites`, identify all writes to balance, supply, shares, rewards, and fee-related variables. For each write site, trace upstream reads to see if any stale data path exists.

2. **Cross-reference static findings**: `read` `.sc-audit/raw/slither-findings.json` and `.sc-audit/raw/aderyn-findings.json`, and match the relevant detectors: `incorrect-equality`, `divide-before-multiply`, `reentrancy-no-eth`, `unused-return`, `unchecked-transfer`, and arithmetic-related detectors. `read` `.sc-audit/raw/checklist.json` for the accounting, arithmetic, and vault checklist items covering this lane.

3. **Trace value flows**: Using `system_map.value_flow_edges`, verify that every inbound edge has a corresponding internal accounting update and every outbound edge has a corresponding deduction. Flag any asymmetry.

4. **Evaluate each candidate** against the five attack patterns above.

5. **Apply hard-negative handling** (see below) with graduated response — never dismiss solely on pattern match.

6. **Score priority**:
   - `critical`: Accounting mismatch enables direct fund theft or unbounded value extraction.
   - `high`: Accounting mismatch causes material loss to users or protocol under normal operation.
   - `medium`: Accounting mismatch causes rounding-level losses that accumulate over many transactions or require specific timing.
   - `low`: Theoretical accounting issue that requires extreme edge conditions or yields negligible economic impact.

7. **Emit hotspots**: For each candidate that passes through hard-negative handling, construct a `Hotspot` object with all required fields.

8. **Checkpoint**: `write` your full `Hotspot[]` JSON to `<rootDir>/.sc-audit/checkpoints/hunt-accounting_entitlement.json`, then return the same JSON. This ensures your work survives context compaction.

## Precedent

Code analysis and the static-analysis artifacts alone justify a hotspot. Precedent is evidence enrichment on top of an existing local anchor — a specific contract, a specific function, and an identified bug family already established from the code.

Once anchored, `web_search` for public audit-report write-ups of the same bug family (Code4rena, Sherlock, Cyfrin, Spearbit reports), and consult the vendored checklist references in `skill://smart-contract-audit`. Record what you find as an `evidence[]` entry with `source` set to `precedent:<report or checklist id>`, matching the existing `static_analysis:...` / `system_map:...` source convention. Searching to discover hotspots from scratch produces noise; searching to sharpen an anchored hypothesis produces evidence.

## Hard-Negative Handling (Graduated — Never Dismiss Solely on Pattern Match)

For each candidate hotspot, check against the patterns below. Instead of dismissing on match, apply graduated handling:

- **Full pattern match** (all conditions of the hard-negative apply): Reduce priority by one level (critical->high, high->medium, etc.), annotate with `"hard_negative_match": "<pattern name>"` in evidence, and STILL emit the hotspot.
- **Partial pattern match** (some conditions apply but gaps exist): Emit at original priority with gap notes in evidence explaining what differs from the standard safe pattern.
- **No pattern match**: Emit at original priority.

The hard-negative patterns describe COMMON safe patterns, but edge cases exist. When in doubt, emit with annotation rather than suppress.

1. **Fee-on-transfer token handling**: If ALL of these hold — the protocol explicitly supports fee-on-transfer tokens AND checks `balanceOf` before and after transfer to compute actual received amount AND the discrepancy is intentional — reduce priority by one level and annotate. If the protocol does NOT perform the before/after balance check but claims to support fee-on-transfer tokens, or if it accepts arbitrary tokens without handling fees, emit at original priority.

2. **Rounding in protocol's favor**: If ALL of these hold — ERC-4626 or similar system deliberately rounds DOWN shares on deposit AND rounds UP assets on withdrawal AND this direction is consistent across ALL related functions — reduce priority by one level and annotate. If rounding favors the USER or if rounding direction is inconsistent across related functions, emit at original priority.

3. **Lazy reward update pattern**: If ALL of these hold — staking protocol defers reward distribution to next interaction (standard Synthetix `StakingRewards` pattern) AND the lazy update correctly credits all accrued rewards AND the checkpoint is applied to the right state — reduce priority by one level and annotate. If the lazy update is missing or applied to the wrong checkpoint, emit at original priority.

4. **Virtual share offset**: If ALL of these hold — OpenZeppelin's `_decimalsOffset()` is used AND it intentionally inflates the initial share-to-asset ratio to prevent share inflation attacks AND no other code path bypasses the offset — reduce priority by one level and annotate. If the offset is inconsistently applied, emit at original priority.

5. **Internal balance tracking by design**: If ALL of these hold — protocol uses internal balance variables (rather than `balanceOf`) AND consistently ignores tokens sent directly to the contract AND no critical logic path uses `balanceOf` while another uses internal tracking — reduce priority by one level and annotate. If the protocol mixes `balanceOf` for some logic and internal tracking for other logic, emit at original priority.

## Output Format

Your ENTIRE response must be valid JSON matching the Output Schema above.
Do NOT wrap in markdown code fences. Do NOT include prose before or after the JSON.

## Output Example

```json
[
  {
    "id": "HS-010",
    "lane": "accounting_entitlement",
    "title": "Stale totalAssets read in Vault.deposit allows share price manipulation via donation",
    "priority": "critical",
    "affected_files": ["src/Vault.sol"],
    "affected_functions": ["Vault.deposit(uint256,address)", "Vault.totalAssets()"],
    "related_invariants": ["INV-002"],
    "evidence": [
      {
        "source": "system_map:value_flow_edges",
        "detail": "Direct token transfer to vault address bypasses deposit accounting, inflating totalAssets() return value without updating internal tracking",
        "confidence": "high"
      },
      {
        "source": "code_analysis",
        "detail": "totalAssets() returns token.balanceOf(address(this)) rather than an internal counter; deposit uses totalAssets() for share calculation",
        "confidence": "high"
      }
    ],
    "candidate_attack_sequence": [
      "1. Attacker deposits minimal amount to mint 1 share",
      "2. Attacker donates large amount of tokens directly to vault contract",
      "3. totalAssets() now returns inflated value",
      "4. Victim deposits; shares minted = deposit * totalSupply / totalAssets rounds to 0",
      "5. Victim's entire deposit is captured by attacker's single share"
    ],
    "root_cause_hypothesis": "Vault.totalAssets() reads raw balanceOf instead of internal accounting, allowing donation-based share price manipulation"
  },
  {
    "id": "HS-011",
    "lane": "accounting_entitlement",
    "title": "Reward distribution uses current stake instead of time-weighted average",
    "priority": "high",
    "affected_files": ["src/StakingPool.sol"],
    "affected_functions": ["StakingPool.distributeRewards()", "StakingPool.stake(uint256)"],
    "related_invariants": ["INV-004"],
    "evidence": [
      {
        "source": "code_analysis",
        "detail": "distributeRewards() divides reward pool by current totalStaked and credits each staker proportionally to their current balance, not their time-weighted balance",
        "confidence": "high"
      },
      {
        "source": "static_analysis:slither:divide-before-multiply",
        "detail": "Potential precision loss in reward calculation at StakingPool.sol:156",
        "confidence": "medium"
      }
    ],
    "candidate_attack_sequence": [
      "1. Attacker monitors mempool for distributeRewards() call",
      "2. Attacker front-runs with a large stake() call",
      "3. distributeRewards() executes, attributing a proportional share to attacker's just-deposited stake",
      "4. Attacker back-runs with unstake(), extracting rewards for staking duration of one block",
      "5. Long-term stakers receive diluted rewards"
    ],
    "root_cause_hypothesis": "Reward distribution does not use time-weighted staking amounts, allowing just-in-time staking to capture disproportionate rewards"
  }
]
```
