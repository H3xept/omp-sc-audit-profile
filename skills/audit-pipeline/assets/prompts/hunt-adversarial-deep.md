# HUNT — Adversarial Deep Lane

## Purpose

Deep adversarial analysis that combines the hotspots produced by every other HUNT lane to find complex, multi-step attack sequences no single lane catches in isolation. This lane reasons about protocol-level composability, flash loan amplification, cross-contract state manipulation, delegatecall chains, callback flows, governance/timelock exploitation, and economic attacks that span multiple transactions and contracts.

The orchestrator activates this lane whenever the system map shows cross-contract interaction patterns — external calls across trust boundaries, delegatecall chains, callback flows, or multi-contract state dependencies — and always in `deep` mode.

This file plus the named inputs are your complete context. Work only from them; assume no conversation history, and treat this file as authoritative if anything else conflicts with it.

## Tools

The tools this lane needs:

- `read` — system map, other lanes' checkpoints, raw static-analysis artifacts, contract source.
- `grep` — locate call sites, state variables, modifiers, and guards across the scope.
- `glob` — enumerate contracts when a chain reaches beyond `scopeFiles`.
- `web_search` — public audit-report precedent, under the anchoring rule below.
- `write` — the single checkpoint artifact named in the Analysis Procedure.

Proof work is not this lane's job: fuzzing and differential harnesses belong to ATTACK via `skill://fuzz-echidna-medusa`, invariant scaffolds via `skill://recon-suite`.

## Inputs

| Name | Type | Required | Description |
|:-----|:-----|:---------|:------------|
| `rootDir` | string | yes | Absolute project root. Checkpoints live under `<rootDir>/.sc-audit/`. |
| `system_map` | path | yes | SystemMapArtifact JSON from the MAP phase. Load it first; every hotspot must cite it. |
| `scopeFiles` | string[] | yes | In-scope contract paths. |
| `combined_hotspots` | paths | yes | `Hotspot[]` checkpoints from the other five lanes (see below). Load every one that exists. |
| `slither_findings` | path | yes | `<rootDir>/.sc-audit/raw/slither-findings.json` — ALL Slither findings, unfiltered. |
| `aderyn_findings` | path | yes | `<rootDir>/.sc-audit/raw/aderyn-findings.json` — ALL Aderyn findings, unfiltered. |
| `checklist` | path | yes | `<rootDir>/.sc-audit/raw/checklist.json` — Cyfrin checklist items for the scope. |

`combined_hotspots` resolves to one checkpoint per standard lane, all under `<rootDir>/.sc-audit/checkpoints/`:

- `hunt-callback_liveness.json`
- `hunt-accounting_entitlement.json`
- `hunt-semantic_consistency.json`
- `hunt-token_oracle_statefulness.json`
- `hunt-economic_differential.json`

A missing checkpoint means that lane did not activate. Continue with the ones present; do not re-run their analysis.

The raw static-analysis artifacts were produced by SETUP and are already on disk. Consume them as files; never invoke the analyzers.

## Output Schema

```json
[
  {
    "id": "<string>",
    "lane": "adversarial_deep",
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

## Adversarial Analysis Methodology

This lane does NOT repeat the analysis of individual lanes. It takes the existing hotspots as building blocks and asks: "How can these be combined, amplified, or chained to create a more severe attack?"

### Phase A — Hotspot Combination Matrix

For every pair of existing hotspots (H_i, H_j) from different lanes, evaluate:

1. **Causal chain**: Can the exploitation of H_i create the precondition for H_j? For example, a callback liveness hotspot (H_i) that gives the attacker execution control during a state update could be chained with an accounting entitlement hotspot (H_j) that exploits stale state.

2. **Shared state**: Do H_i and H_j affect overlapping state variables or contracts? If modifying state via H_i changes the invariants that H_j relies on, the combination may be exploitable even if each hotspot individually has mitigations.

3. **Temporal ordering**: Can H_i and H_j be executed in the same transaction (via flash loan or callback)? If yes, atomicity amplifies the attack by removing the risk of partial execution.

Focus on pairs that span different contract boundaries, as cross-contract interactions are the most commonly missed attack vectors.

### Phase B — Multi-Step Attack Sequences (3+ Transactions)

For each promising hotspot pair (or triplet) from Phase A, construct a concrete multi-step attack sequence. Each sequence MUST:

1. Specify at least 3 distinct steps (transactions or intra-transaction calls).
2. Identify the attacker's starting position (capital, permissions, deployed contracts).
3. Trace state changes at each step, showing how the world state evolves.
4. Identify the final exploitation point where value is extracted.
5. Estimate the amplification factor (how much more damage the multi-step attack causes compared to individual hotspots).

### Phase C — Semantic Tension Analysis

For each high-priority hotspot from Phase A or B:

1. **Argue "preserves invariant"**: Construct the strongest possible argument that this code path preserves all relevant protocol invariants. Identify every guard, check, and design choice that supports safety.

2. **Argue "enables exploit"**: Construct the strongest possible argument that this code path can be exploited. Identify every assumption, edge case, and composition that supports the attack.

3. **Evaluate tension**: When BOTH arguments survive scrutiny (neither is clearly wrong), this is a semantic tension point. Escalate to `critical` or `high` priority — these are the findings most likely to be real and most likely to be missed by other analysis.

4. **Emit as hotspot**: If semantic tension exists, emit with evidence containing both arguments. The ATTACK phase will resolve the tension with concrete proof.

## Attack Patterns to Investigate

### Pattern 1 — Cross-Contract State Manipulation via Re-Entry or Callback Chaining

Combine callback liveness hotspots with accounting or semantic hotspots:

- **Reentrancy + stale state**: A callback from Contract A allows re-entering Contract B while A's state is partially updated. If B reads A's state (directly or indirectly), B sees an inconsistent view.
- **Callback chaining**: First callback triggers a second callback in a different contract, creating a chain where each contract sees a different state snapshot.
- **ERC-777 + ERC-4626**: Vault deposit/withdrawal with an ERC-777 token that triggers a hook, which re-enters the vault's share calculation before balances are updated.
- **Delegatecall chains**: A `delegatecall` executes foreign code in the caller's storage context. Chase chains where A delegatecalls B which calls C, and check whether storage layout assumptions, reentrancy guards, or `msg.sender`/`address(this)` semantics hold at every hop.

Scan `system_map.external_call_sites` for chains where Contract A calls Contract B which calls Contract C, and any of A, B, or C have incomplete state updates during the chain. `grep` for `delegatecall`, `call(`, and hook selectors (`onERC721Received`, `tokensReceived`, `uniswapV3SwapCallback`, `onFlashLoan`) to find hops the map may have missed.

### Pattern 2 — Flash Loan Amplification

For each existing hotspot that involves value manipulation (accounting entitlement, oracle staleness, semantic fee mismatch, economic differential):

- **Capital amplification**: Can the attacker use a flash loan to amplify the exploit? If a hotspot allows extracting 0.1% of the input amount, a $10M flash loan turns that into $10,000 profit per transaction.
- **Price manipulation**: Can a flash loan temporarily move a spot price, trigger an oracle-dependent action, and revert the price — all within a single transaction?
- **Liquidity draining**: Can a flash loan be used to empty one side of a pool, making the attack on the other side more profitable?

For each hotspot with a value flow component, calculate whether flash loan amplification makes an otherwise low-priority issue into a critical one.

### Pattern 3 — Governance/Timelock Interaction with DeFi Composability

Analyze the protocol's governance and timelock mechanisms in the context of DeFi composability:

- **Governance proposal + flash loan vote**: Can an attacker use a flash loan to acquire governance tokens, vote on a proposal, and return the tokens — all in one transaction? Check if voting power is snapshot-based or instantaneous.
- **Timelock parameter change + exploit window**: When a governance proposal changes a critical parameter (fee rate, oracle address, collateral factor), is there a window during the timelock delay where the pending change creates an exploitable condition?
- **Queue flooding**: Can an attacker flood the timelock queue to delay legitimate governance actions?
- **Cross-protocol governance**: If the protocol uses governance tokens from another protocol (or is governed by a DAO that governs multiple protocols), can an action in one protocol create an exploit in another?

Cross-reference `system_map.auth_surfaces` for governance-related functions and `system_map.config_semantics` for parameters that governance can change.

### Pattern 4 — Economic Attacks (Sandwich, Oracle Manipulation + Liquidation)

Construct economic attack scenarios that combine market conditions with protocol mechanics:

- **Sandwich attacks**: For any function that executes a swap or price-dependent operation, can an attacker sandwich the transaction (front-run to move price, let victim execute at worse price, back-run to capture profit)?
  - Check: Does the function accept and enforce `minAmountOut` or `deadline` parameters?
  - Check: Is the function called by other contracts (no slippage protection in internal calls)?

- **Oracle manipulation + cascading liquidation**: Can an attacker manipulate an oracle price, trigger mass liquidations, and profit from the liquidation discounts?
  - Step 1: Flash loan large amount of collateral token.
  - Step 2: Dump on DEX to crash spot price.
  - Step 3: If oracle uses spot price (or short TWAP), protocol sees depressed price.
  - Step 4: Liquidation engine marks positions as undercollateralized.
  - Step 5: Attacker (or accomplice) liquidates positions at a discount.
  - Step 6: Attacker repays flash loan after buying back the token at the crashed price.

- **Just-in-time liquidity**: Can an attacker provide liquidity just before a large trade and remove it immediately after, capturing fees without bearing ongoing risk?

### Pattern 5 — State Dependency Across Protocol Boundaries

If the protocol integrates with external protocols (Uniswap, Aave, Compound, Chainlink, etc.):

- **External protocol upgrade risk**: What happens if an integrated protocol upgrades and changes its interface or behavior?
- **External protocol pausing**: If the integrated protocol pauses (Chainlink feeds go stale, Aave pauses a market), does this protocol handle the pause gracefully or does it lock funds?
- **Composability assumptions**: Does the protocol assume properties of the external protocol that are not guaranteed? For example, assuming a Uniswap pool will always have liquidity, or assuming a Chainlink feed will always return positive prices.
- **Multi-contract state dependency**: Where two in-scope contracts each cache or derive a value the other owns, check whether any ordering of updates leaves the pair mutually inconsistent for an attacker-controlled window.

## Precedent Lookup

Precedent is evidence enrichment, never discovery. Search only after a **local anchor** exists — a specific contract, a specific function, and an identified bug family already derived from the code in front of you.

With an anchor in hand:

- `web_search` for public audit-report precedent on that bug family in that protocol shape (for example: "ERC4626 vault donation inflation attack audit finding").
- Cross-check the vendored Cyfrin checklist references in `skill://smart-contract-audit` and the scope's own `.sc-audit/raw/checklist.json` items for the matching category.

Record what you learn as an `evidence[]` entry with `"type": "precedent"` where the schema already carries that slot; otherwise use a descriptive `source` string and keep the code-level evidence as the load-bearing entry. A hotspot's existence always rests on local code, not on an external report.

## Analysis Procedure

1. **Load inputs**: With `read`, pull in `system_map`, every available lane checkpoint under `combined_hotspots`, and all four raw artifacts — including `storage-layout.json`, which is the authority on slots and byte widths when a chain runs through a `delegatecall` or a proxy. Static findings are unfiltered on purpose — low-severity analyzer noise often supplies the missing link in a chain.

2. **Build combination matrix**: Create all pairs from the combined hotspots where the two hotspots are from different lanes. For each pair, evaluate the three criteria (causal chain, shared state, temporal ordering).

3. **Identify flash loan amplification candidates**: For each existing hotspot with an economic impact, evaluate flash loan amplification potential.

4. **Analyze governance attack surface**: If the protocol has governance, evaluate governance-specific attack vectors.

5. **Construct multi-step attack sequences**: For each promising combination, build a detailed attack sequence with 3+ steps.

6. **Apply semantic tension analysis**: For each high-priority hotspot from steps 2-5, apply Phase C (argue both sides — preserves invariant vs. enables exploit). Escalate semantic tension points.

7. **Score priority**:
   - `critical`: Multi-step attack enables protocol insolvency, permanent fund loss, or governance takeover. Flash loan makes it capital-efficient.
   - `high`: Multi-step attack enables significant value extraction but requires specific market conditions or timing.
   - `medium`: Attack sequence is theoretically viable but requires unlikely conditions, high capital, or has limited profit.
   - `low`: Attack sequence is speculative or requires conditions that are extremely unlikely in practice.

8. **Apply hard-negative handling** (see below) with graduated response — never dismiss solely on pattern match.

9. **Emit hotspots**: For each viable multi-step attack, construct a `Hotspot` object. The `candidate_attack_sequence` field should contain at least 3 steps.

10. **Checkpoint**: Use `write` to save your complete `Hotspot[]` JSON to `<rootDir>/.sc-audit/checkpoints/hunt-adversarial_deep.json`, then return that same JSON as your response. This is the only file this lane writes.

## Hard-Negative Handling (Graduated — Never Dismiss Solely on Pattern Match)

For each candidate hotspot, check against the patterns below. Instead of dismissing on match, apply graduated handling:

- **Full pattern match** (all conditions of the hard-negative apply): Reduce priority by one level (critical->high, high->medium, etc.), annotate with `"hard_negative_match": "<pattern name>"` in evidence, and STILL emit the hotspot.
- **Partial pattern match** (some conditions apply but gaps exist): Emit at original priority with gap notes in evidence explaining what differs from the standard safe pattern.
- **No pattern match**: Emit at original priority.

**NEVER dismiss a hotspot solely because a hard-negative partially matches.** The hard-negative patterns describe COMMON safe patterns, but edge cases exist. When in doubt, emit with annotation rather than suppress.

1. **Individual hotspots already mitigated**: If ALL of these hold — every constituent hotspot in the combination has been fully mitigated by its lane's hard-negative analysis AND the mitigations are independent (mitigating H_i does not weaken the mitigation of H_j) — reduce priority by one level and annotate. If mitigations interact or overlap, emit at original priority.

2. **Flash loan amplification not viable**: If ALL of these hold — the exploit requires maintaining state across multiple transactions (flash loan must be repaid in same tx) AND no single-transaction attack path exists — reduce priority by one level and annotate. If a single-transaction path exists, emit at original priority.

3. **Governance timelock prevents atomic exploitation**: If ALL of these hold — governance parameter changes go through a timelock AND the timelock period is sufficient for community response AND no way to bypass the timelock exists — reduce priority by one level and annotate. If the timelock can be bypassed or the delay is too short, emit at original priority.

## Lane discipline

- Every emitted hotspot adds NEW attack insight: a combination, an amplification, or a multi-step sequence that no individual lane captured. Restating another lane's hotspot at a higher severity is not a finding of this lane.
- Every hotspot names specific contracts, functions, and state variables drawn from `system_map` and the source. Grounding is what separates a hotspot from a guess.
- Hotspots are hypotheses. `priority` is a triage signal for ATTACK, which assigns final severity after proof.
- `lane` is always `"adversarial_deep"`.
- Privilege handling follows the canonical rule in `skill://audit-pipeline/assets/prompts/da-protocol.md`: privileged roles act in good faith, so direct admin self-attack is out of scope, while authority propagation through honest components, composition failures across protocols, flash-loan governance attacks, and config interaction vectors are all squarely in scope.

Two hard guardrails:

- NEVER emit prose, markdown, or commentary — the response is the JSON array and nothing else.
- NEVER let an external precedent report, on its own, be the basis for a hotspot; the anchor is always local code.

## Output Format

Your ENTIRE response must be valid JSON matching the Output Schema above.
Do NOT wrap in markdown code fences. Do NOT include prose before or after the JSON.

## Output Example

```json
[
  {
    "id": "HS-050",
    "lane": "adversarial_deep",
    "title": "Flash loan + stale oracle + cascading liquidation enables protocol insolvency",
    "priority": "critical",
    "affected_files": ["src/PriceOracle.sol", "src/LendingPool.sol", "src/LiquidationEngine.sol"],
    "affected_functions": [
      "PriceOracle.getLatestPrice(address)",
      "LendingPool.borrow(address,uint256)",
      "LiquidationEngine.liquidate(address,address)"
    ],
    "related_invariants": ["INV-002", "INV-007"],
    "evidence": [
      {
        "source": "hotspot_combination:HS-030+HS-011",
        "detail": "HS-030 (stale oracle in PriceOracle) combined with HS-011 (reward timing in StakingPool). Stale oracle allows over-borrowing; simultaneous reward claim amplifies extracted value",
        "confidence": "high"
      },
      {
        "source": "system_map:value_flow_edges",
        "detail": "LendingPool.borrow() uses PriceOracle for collateral valuation. Flash loan provides collateral, stale price inflates valuation, borrow extracts more than collateral is worth",
        "confidence": "high"
      },
      {
        "source": "system_map:external_call_sites",
        "detail": "LiquidationEngine.liquidate() also uses PriceOracle; stale price prevents timely liquidation of the attacker's position",
        "confidence": "medium"
      }
    ],
    "candidate_attack_sequence": [
      "1. Attacker monitors Chainlink feed for delayed update (e.g., high volatility period with >1hr staleness)",
      "2. Attacker takes flash loan of 10,000 ETH from Aave",
      "3. Attacker deposits flash-loaned ETH as collateral in LendingPool at stale high price",
      "4. Attacker borrows maximum USDC against inflated collateral valuation",
      "5. Attacker swaps borrowed USDC for ETH on Uniswap (partially repaying flash loan)",
      "6. Attacker repays flash loan with remaining ETH",
      "7. When oracle updates to current (lower) price, attacker's position is undercollateralized",
      "8. Protocol absorbs bad debt; LiquidationEngine cannot recover full value"
    ],
    "root_cause_hypothesis": "Combination of missing oracle staleness check (HS-030) and flash loan capital amplification allows an attacker to borrow against inflated collateral valuation, extracting protocol value as bad debt when the oracle eventually updates"
  },
  {
    "id": "HS-051",
    "lane": "adversarial_deep",
    "title": "ERC-777 callback reentrancy chains through Vault into RewardDistributor to steal rewards",
    "priority": "high",
    "affected_files": ["src/Vault.sol", "src/RewardDistributor.sol", "src/AccountingModule.sol"],
    "affected_functions": [
      "Vault.withdraw(uint256,address,address)",
      "RewardDistributor.claimRewards(address)",
      "AccountingModule.sync()"
    ],
    "related_invariants": ["INV-002", "INV-004", "INV-005"],
    "evidence": [
      {
        "source": "hotspot_combination:HS-001+HS-011",
        "detail": "HS-001 (ERC-777 callback in Vault.withdraw) provides execution control. HS-011 (reward attribution using current stake) is exploitable during the callback window when share state is inconsistent",
        "confidence": "high"
      },
      {
        "source": "system_map:external_call_sites",
        "detail": "Vault.withdraw safeTransfer fires before share burn. During callback, attacker's share balance is still at pre-withdrawal level. RewardDistributor.claimRewards reads share balance for reward calculation",
        "confidence": "high"
      }
    ],
    "candidate_attack_sequence": [
      "1. Attacker deposits ERC-777 token into Vault, receiving shares",
      "2. Reward epoch ends; rewards are allocated based on current shares",
      "3. Attacker calls Vault.withdraw() to redeem all shares",
      "4. During safeTransfer callback (ERC-777 tokensReceived), attacker calls RewardDistributor.claimRewards()",
      "5. RewardDistributor reads attacker's share balance, which is still at pre-withdrawal level (shares not yet burned)",
      "6. Attacker receives full reward allocation for shares they are in the process of withdrawing",
      "7. Vault.withdraw completes, burning shares",
      "8. Attacker extracted both the underlying assets AND the full reward allocation"
    ],
    "root_cause_hypothesis": "Vault.withdraw performs token transfer (with ERC-777 callback) before burning shares, creating a window where RewardDistributor sees inflated share balance and distributes rewards for shares being withdrawn"
  }
]
```
