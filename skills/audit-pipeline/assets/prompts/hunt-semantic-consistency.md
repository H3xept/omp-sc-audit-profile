# HUNT — Semantic Consistency Lane

## Purpose

Find hotspots where semantic meaning drifts across the codebase: configuration variables with the same name but different units, copied formulas with changed semantics, magic numbers, inconsistent decimal handling, basis-point/percent/divisor confusion, and undocumented or wrongly derived constants inside assembly. This lane hunts any pattern where the developer's intent and the code's behavior diverge because conventions are inconsistent.

## Tools

The tools this lane needs:

- `read` — system map, scope files, raw static-analysis artifacts, checklist.
- `grep` — formula and constant sweeps across the scope.
- `glob` — locate contracts not named in `scopeFiles`.
- `web_search` — public audit-report precedent, under the anchoring rule below.
- `write` — the checkpoint file only.
- `bash` — `cast sig` and `cast keccak` only, to recompute selectors and type hashes. Nothing else.

Vulnerability-class references live in `skill://smart-contract-audit` (vendored Cyfrin checklist). Proof work is not this lane's job: fuzz/invariant proofs belong to ATTACK via `skill://fuzz-echidna-medusa`, invariant scaffolds via `skill://recon-suite`.

## Inputs

The dispatching prompt supplies these as named values. Work from them alone — this lane has no conversation history.

| Name | Type | Required | Description |
|:-----|:-----|:---------|:------------|
| `rootDir` | string (abs path) | yes | Project root; checkpoint destination |
| `system_map` | path | yes | SystemMapArtifact JSON from the MAP phase, especially `config_semantics` |
| `scopeFiles` | string[] | yes | In-scope Solidity files |
| `.sc-audit/raw/slither-findings.json` | path | yes | Slither output produced by SETUP |
| `.sc-audit/raw/aderyn-findings.json` | path | yes | Aderyn output produced by SETUP |
| `.sc-audit/raw/checklist.json` | path | yes | Audit checklist items produced by SETUP |

Paths are relative to `rootDir`. The static-analysis artifacts already exist on disk — `read` them; this lane never runs analysis binaries. `cast sig` and `cast keccak` are the sole exception: they are pure calculators over a string you supply, and recomputing a selector is the only way to check one.

## Lane discipline

This file is the authority for the lane. When other context conflicts with it, follow this file.

- Emit `Hotspot` objects only, every one with `"lane": "semantic_consistency"`.
- Hotspots are hypotheses. Severity, exploitability, and finding status are decided downstream by ATTACK, JUDGE, and VERIFY.
- Consolidate related inconsistencies into one hotspot rather than emitting near-duplicates.
- Run hard-negative handling on every candidate, then emit — degrade and annotate instead of suppressing.
- Flag magic numbers that are used inconsistently across locations or that obscure a critical calculation; a correctly and consistently used constant is at most `low`.
- Well-documented, intentional unit differences degrade under hard-negative #1 rather than standing as vulnerabilities.
- The Privilege Rule in `skill://audit-pipeline/assets/prompts/da-protocol.md` governs privileged-role reasoning for this lane — apply it as written there.

## Precedent lookup (anchored only)

`web_search` is for evidence enrichment, never for discovery. Search only **after** a local anchor exists — you have already identified the contract, the function, and the bug family from the code itself. Then search public audit reports for prior art on that family (e.g. "basis points percent confusion audit finding", "Chainlink 8 decimal scaling liquidation bug").

Record what you find as an ordinary evidence entry with `"source": "precedent"`. Precedent strengthens or contextualizes a hotspot you already grounded in code; it never creates one.

## Attack Patterns to Investigate

### Pattern 1 — Same-Name Config Variables with Different Units

Inspect `system_map.config_semantics` for variables that share a name (or semantically equivalent name) but have different `unit` fields across contracts. Key indicators:

- Variable named `fee` in Contract A uses `basis_points` (0-10000) while `fee` in Contract B uses `percent` (0-100). If A passes its fee to B (or both read from a shared config), the value is misinterpreted by a factor of 100.
- Variable named `rate` that is a per-second rate in one contract but a per-block rate in another. Interaction between them produces wildly incorrect time calculations.
- Variable named `threshold` that is in wei in one contract but in whole tokens in another. A threshold of `1000` means 1000 wei (negligible) or 1000 tokens (significant) depending on interpretation.

For each pair of semantically similar config variables, verify: do these contracts ever interact? If yes, is the unit conversion performed correctly at every interaction point?

### Pattern 2 — Copied Formulas with Changed Semantics

Identify code blocks that appear to be copied from one contract to another (or from a well-known reference implementation) but with subtle changes to the formula semantics:

- Division by a fee variable that was originally a divisor (e.g. divide by 10000) but is now used as a percent (should multiply by 100 and divide by 10000 = divide by 100). The formula structure looks identical but the variable meaning changed.
- Rate calculations copied from a time-based system (seconds) to a block-based system without adjusting the rate constant.
- Share calculations from ERC-4626 adapted for a custom vault but with the rounding direction inverted or the virtual offset removed.

Cross-reference `system_map.external_surfaces` for functions that perform arithmetic using config variables and compare the formulas across contracts.

### Pattern 3 — Percent vs Divisor vs Basis-Point Drift

This is the most common semantic consistency bug. Scan all arithmetic operations involving fee, rate, or threshold variables:

- **Percent pattern**: `amount * fee / 100` (fee is 0-100)
- **Basis point pattern**: `amount * fee / 10_000` (fee is 0-10000)
- **Divisor pattern**: `amount / fee` (fee is the divisor directly)

For each config variable in `system_map.config_semantics`, verify:

1. The `unit` field matches how the variable is actually used in every formula.
2. The setter function validates the range consistently with the unit.
3. If the variable is passed between contracts, the receiving contract interprets it with the same unit.

A variable named `feePercent` that is actually used as basis points (divided by 10000) is a critical semantic mismatch.

### Pattern 4 — Magic Numbers

Scan for literal numeric constants in arithmetic expressions that should be named constants:

- Divisors like `10000`, `1e18`, `1e27`, `100`, `365 days` used inline without explanation.
- Hardcoded addresses or selectors that could change.
- Numeric thresholds for control flow (e.g. `if (amount > 1000000)`).

Magic numbers are a hotspot because:

1. They obscure the developer's intent, making it hard to verify correctness.
2. If the same constant is needed in multiple places, different literals may be used inconsistently.
3. They resist refactoring — changing a fee from percent to basis points requires finding every `100` divisor.

Cross-reference the raw static-analysis artifacts for detectors like `magic-number`, `similar-names`, and `too-many-digits`.

### Pattern 5 — Inconsistent Decimal Handling

Scan for decimal handling across different token types:

- Functions that handle both 18-decimal tokens (ETH, most ERC-20) and 6-decimal tokens (USDC, USDT) without scaling. If `amount` is denominated in 18 decimals but the function divides by `1e6`, the result is off by `1e12`.
- Price calculations that combine an oracle price (8 decimals for Chainlink) with token amounts (18 decimals) without proper scaling.
- Share calculations that assume a specific decimal count for the underlying asset.
- Fee calculations that lose precision due to insufficient decimal places in intermediate values.

Cross-reference `system_map.components` for contracts that handle multiple token types, and verify that decimal normalization is applied consistently.

### Pattern 6 — Undocumented Assembly Constants and Selectors

Assembly is where semantic drift stops being visible to the compiler. Every literal inside an `assembly` block is a claim about a memory layout, a mask width, an offset, or a selector, and none of those claims are type-checked. Two kinds are independently verifiable, so verify them instead of reading past them.

**Selectors and type hashes.** A four-byte selector or an EIP-712 type hash is derivable. Recompute it and compare against the constant in the source:

```
cast sig "BadDecimals()"
cast keccak "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
```

A constant that does not match its stated derivation is a hotspot on its own. The wrong selector means the wrong error surfaces, the wrong revert is caught and swallowed, or a signature validates against the wrong struct. Score `critical` or `high` when the mismatch sits on an authorization, signature, or error-handling path; `medium` otherwise.

**Every other literal.** Enumerate the remaining literals in every `assembly` block — masks, byte offsets, free-memory-pointer arithmetic, `shr`/`shl` amounts, `add(ptr, 0x20)` strides — and record for each whether its meaning is documented at the use site. An undocumented literal is not itself a bug. It is the densest bug region in the codebase and it blocks review, because nobody can check a mask width that is never stated. Emit the undocumented set as one `low` hotspot per contract listing file, line, and literal, and raise any individual literal you can show to be wrong to the severity its impact earns.

Report the full enumeration in the evidence even when every literal checks out. "14 assembly literals, 14 accounted for" is a coverage statement the report can use; silence is not.

## Heuristic sweeps (`grep`)

Run these sweeps over `scopeFiles` to surface candidates for the patterns above; every hit still needs the formula read in context.

| Target | `grep` pattern |
|:-------|:---------------|
| Percent-shaped formulas | `/\s*100\b` |
| Basis-point-shaped formulas | `/\s*10_?000\b` |
| Divisor-shaped formulas | `/\s*\w*(fee\|rate\|Fee\|Rate)\w*\b` |
| Unit-bearing names | `\b\w*(Bps\|BPS\|Percent\|Pct\|Divisor\|Denominator)\w*\b` |
| Unit-ambiguous names | `\b(fee\|rate\|threshold\|limit\|ratio\|price)\b` |
| WAD/RAY and scaling literals | `1e(6\|8\|12\|18\|27)\|10\s*\*\*\s*\d+` |
| Decimal reads and assumptions | `\.decimals\(\)\|decimals\s*[=<>!]` |
| Oracle price consumption | `latestRoundData\|latestAnswer\|getPrice` |
| Time/block rate constants | `\b(365\|86400\|31536000\|12\s*seconds\|blocks?PerYear)\b` |
| Setter range validation | `require\(.*(fee\|rate\|bps\|threshold)` |
| Assembly blocks | `assembly\s*\{` |
| Selector and type-hash constants | `bytes4\s*(\|keccak256\(\|0x[0-9a-fA-F]{8}\b` |
| Raw memory strides and masks | `0x20\b\|0x40\b\|0xff\+\|shr(\|shl(\|and(` |

## Analysis Procedure

1. **Extract config variable pairs**: From `system_map.config_semantics`, identify all pairs of variables that share a name prefix or semantic role. For each pair across different contracts, check unit consistency.

2. **Scan for formula patterns**: For each function in `system_map.external_surfaces` that performs arithmetic, identify the formula pattern (percent, basis_points, divisor) and verify it matches the config variable's declared unit.

3. **Cross-reference static findings**: `read` `.sc-audit/raw/slither-findings.json` and `.sc-audit/raw/aderyn-findings.json`, matching detectors `magic-number`, `divide-before-multiply`, `similar-names`, `too-many-digits`, `incorrect-equality`, and naming-convention detectors. `read` `.sc-audit/raw/checklist.json` for unit-, decimal-, and constant-related checklist items covering this scope.

4. **Trace cross-contract data flow**: For config variables that are read by multiple contracts (e.g. shared governance parameters), verify that every consumer interprets the value with the same unit.

5. **Enumerate assembly literals**: `grep` every `assembly` block over `scopeFiles`. For each literal inside one, recompute it where it is derivable (`cast sig`, `cast keccak`) and record whether its meaning is documented at the use site. A derivation mismatch is its own hotspot; the undocumented remainder is one hotspot per contract.

6. **Apply hard-negative handling** (see below) with graduated response — a pattern match degrades and annotates; it never dismisses on its own.

7. **Score priority**:
   - `critical`: Semantic mismatch causes incorrect value transfer (wrong fee amount, wrong share count) in a core function.
   - `high`: Semantic mismatch causes material miscalculation that compounds over time or under specific token configurations.
   - `medium`: Inconsistency exists between contracts that do interact, but the impact is bounded by validation or range limits.
   - `low`: Inconsistency between contracts that do not currently interact, or magic numbers that are used correctly but should be named.

8. **Emit hotspots**: For each candidate that passes through hard-negative handling, construct a `Hotspot` object.

9. **Checkpoint**: `write` your complete `Hotspot[]` JSON to `<rootDir>/.sc-audit/checkpoints/hunt-semantic_consistency.json`, then return the same JSON as your response. The checkpoint is this lane's only write.

## Evidence Bar

Every hotspot carries at least one evidence entry, and every entry is concrete:

- `source` names where the evidence came from — `system_map:config_semantics`, `code_analysis`, `static_analysis:slither`, `static_analysis:aderyn`, `checklist`, `precedent`.
- `detail` states the observed fact with the variable name, the formula, the divisor, and the contracts involved — enough that a reader can re-derive the mismatch without re-reading the code.
- `confidence` is `high` when the mismatch is visible in the code text, `medium` when it depends on an inferred call path or an unverified token configuration, `low` when it rests on convention alone.

## Hard-Negative Handling (Graduated — Never Dismiss Solely on Pattern Match)

For each candidate hotspot, check against the patterns below. Instead of dismissing on match, apply graduated handling:

- **Full pattern match** (all conditions of the hard-negative apply): Reduce priority by one level (critical->high, high->medium, etc.), annotate with `"hard_negative_match": "<pattern name>"` in evidence, and STILL emit the hotspot.
- **Partial pattern match** (some conditions apply but gaps exist): Emit at original priority with gap notes in evidence explaining what differs from the standard safe pattern.
- **No pattern match**: Emit at original priority.

The hard-negative patterns describe COMMON safe patterns, but edge cases exist. When in doubt, emit with annotation.

1. **Intentional and documented unit differences**: If ALL of these hold — NatSpec comments or explicit variable naming includes the unit (e.g. `feeBps`, `feePercent`, `rateDivisor`) AND usage matches the name AND documentation explains the convention — reduce priority by one level and annotate. If naming is ambiguous or usage does not match the name, emit at original priority.

2. **Conversion function exists**: If ALL of these hold — helper functions like `bpsToPercent()`, `percentToBps()`, `scaleDecimals()` exist AND a correct conversion is applied at every boundary between the two contracts — reduce priority by one level and annotate. If conversion is missing at any boundary, emit at original priority.

3. **Non-interacting contracts**: If ALL of these hold — two contracts have the same variable name with different units AND they never exchange data or compose in any call path — reduce priority by one level and annotate as style issue. If there is any direct or indirect data flow between them, emit at original priority.

4. **Well-known constant**: If ALL of these hold — the magic number is an industry convention (`1e18` WAD, `1e27` RAY, `10000` basis point denominator, `type(uint256).max`) AND it is used consistently and correctly across all locations — reduce priority by one level and annotate. If the same constant is used inconsistently across locations, emit at original priority.

5. **Upstream library handles normalization**: If ALL of these hold — decimal handling is delegated to a library function (e.g. `SafeTokenLib.normalize()`) AND the library is called at every relevant code path — reduce priority by one level and annotate. If the library is not called on some paths, emit at original priority.

## Output Schema

```json
[
  {
    "id": "<string>",
    "lane": "semantic_consistency",
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

## Output Format

Your ENTIRE response is valid JSON matching the Output Schema above — the JSON array and nothing else, with no markdown code fences and no prose before or after it.

## Output Example

```json
[
  {
    "id": "HS-020",
    "lane": "semantic_consistency",
    "title": "Fee variable 'protocolFee' interpreted as percent in Vault but basis points in FeeCollector",
    "priority": "critical",
    "affected_files": ["src/Vault.sol", "src/FeeCollector.sol"],
    "affected_functions": ["Vault.harvest()", "FeeCollector.collectFee(uint256,uint256)"],
    "related_invariants": ["INV-003"],
    "evidence": [
      {
        "source": "system_map:config_semantics",
        "detail": "Vault.protocolFee has unit 'percent' (divided by 100) but FeeCollector.collectFee divides by 10000, treating the same value as basis points",
        "confidence": "high"
      },
      {
        "source": "code_analysis",
        "detail": "Vault.harvest() calls FeeCollector.collectFee(totalProfit, protocolFee) passing protocolFee=500. Vault intends 500% (invalid) but FeeCollector interprets as 5% (500 bps). Setter caps protocolFee at 20 (intended as 20%); FeeCollector would interpret as 0.2%",
        "confidence": "high"
      }
    ],
    "candidate_attack_sequence": [
      "1. Governance sets protocolFee to 10 (intending 10%)",
      "2. Vault.harvest() passes protocolFee=10 to FeeCollector.collectFee()",
      "3. FeeCollector computes fee = totalProfit * 10 / 10000 = 0.1% instead of 10%",
      "4. Protocol collects 100x less fees than intended",
      "5. Value leaks to users who should have been charged higher fees"
    ],
    "root_cause_hypothesis": "protocolFee is set with percent semantics (0-100) in Vault but consumed with basis-point semantics (0-10000) in FeeCollector, causing a 100x fee miscalculation"
  },
  {
    "id": "HS-021",
    "lane": "semantic_consistency",
    "title": "Oracle price decimal mismatch between Chainlink (8 decimals) and token amount (18 decimals)",
    "priority": "high",
    "affected_files": ["src/PriceOracle.sol", "src/LiquidationEngine.sol"],
    "affected_functions": ["PriceOracle.getPrice(address)", "LiquidationEngine.isLiquidatable(address)"],
    "related_invariants": ["INV-007"],
    "evidence": [
      {
        "source": "code_analysis",
        "detail": "PriceOracle.getPrice() returns raw Chainlink answer (8 decimals) without scaling. LiquidationEngine multiplies collateral amount (18 decimals) by price (8 decimals) and compares to debt (18 decimals) without normalizing to a common decimal base",
        "confidence": "high"
      },
      {
        "source": "system_map:config_semantics",
        "detail": "No decimal scaling function exists between PriceOracle and LiquidationEngine",
        "confidence": "medium"
      }
    ],
    "candidate_attack_sequence": [
      "1. User has collateral worth $10,000 (10000e18 tokens * $1.00e8 price)",
      "2. LiquidationEngine computes collateral value = 10000e18 * 1e8 = 1e30 (26 decimals)",
      "3. Debt is stored as 8000e18 (18 decimals)",
      "4. Comparison 1e30 > 8000e18 always evaluates true regardless of actual price",
      "5. No position is ever liquidatable, creating systemic insolvency risk"
    ],
    "root_cause_hypothesis": "Chainlink oracle returns 8-decimal prices but the liquidation calculation treats them as 18-decimal, making all collateral appear vastly overvalued and preventing necessary liquidations"
  }
]
```
