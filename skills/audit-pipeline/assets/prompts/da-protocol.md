# Devil's Advocate (DA) Protocol — Canonical

Single source of truth for the DA evaluation. ATTACK (Step 3) and VERIFY (skeptic) both run this protocol unchanged.

## Lane discipline

This file defines your whole job. It outranks anything else visible to you: treat the dispatching prompt's named inputs as your only inputs, stay inside this phase, and return exactly the JSON in the Output Schema.

## Six dimensions

Evaluate each dimension independently. Every dimension gets concrete evidence found with `grep` and `read` in the codebase — a score with no evidence string is not a score.

| # | Dimension | ID | What to search for |
|---|-----------|-----|-------------------|
| 1 | Guards | `guards` | `require`, `assert`, `revert`, modifiers that block any step of the attack sequence |
| 2 | Reentrancy protection | `reentrancy_protection` | `nonReentrant`, custom mutex, checks-effects-interactions pattern on affected AND cross-contract paths |
| 3 | Access control | `access_control` | Can the attacker actually call each function in the sequence? Apply the Privilege Rule |
| 4 | By-design classification | `by_design` | Is the behavior documented? Safe / Risky tradeoff / Undocumented |
| 5 | Economic feasibility | `economic_feasibility` | Capital required, gas costs, expected profit. Cost > yield = partial mitigation |
| 6 | Dry run | `dry_run` | Execute the exploit sketch with concrete values. Check arithmetic behavior, rounding, overflow |

All six are always evaluated. A dimension with nothing found scores `0` with evidence "no relevant guard found in <files searched>".

## Scoring scale

Scores come from this closed set: `-3`, `-2`, `-1`, `0`, `+1`.

| Score | Label | Meaning |
|:------|:------|:--------|
| -3 | Full mitigation | Complete guard that prevents the attack under ALL conditions |
| -2 | Safe by design | Documented behavior with no security impact |
| -1 | Partial mitigation | Guard exists but has edge cases, race conditions, or can be bypassed |
| 0 | No mitigation | Nothing relevant found |
| +1 | Edge-case exploitable | The "mitigation" actually introduces a new vector or has a known bypass |

## By-design classification (dimension 4)

Three-way classification — choose exactly one. "By design" is a classification, never an automatic dismissal.

| Classification | Score | Criteria |
|:---------------|:------|:---------|
| Safe by design | -2 | Documented behavior WITH no security impact |
| Risky tradeoff | 0 | Documented behavior BUT creates attack surface. Emit finding with `category = "design_tradeoff"` |
| Undocumented | 0 | No documentation found. Proceed normally |

## Privilege rule

Privileged roles (owner, admin, governance) ACT in good faith. Access control alone therefore never dismisses a finding. These four patterns survive privileged-role reasoning and stay in scope:

1. **Authority propagation**: an honest admin sets a parameter that enables an unprivileged user's exploit.
2. **Composition failures**: an admin action in protocol A enables an exploit in protocol B.
3. **Flash-loan governance**: governance power can be borrowed temporarily.
4. **Config interaction**: an admin sets two individually-valid parameters that together create a vulnerability.

## Decision rules

Sum all six dimension scores to get `da_total_score`. Apply:

| Condition | Decision | `da_verdict` |
|:----------|:---------|:-------------|
| At least one -3 AND total <= -6 | INVALIDATED — attack is impossible | `invalidated` |
| Total <= -6 with no -3 present | Degrade confidence to "Possible" | `degraded` |
| Total between -5 and -3 (inclusive) | Degrade confidence to "Possible" | `degraded` |
| Total between -2 and +2 (inclusive) | Keep confidence as "Likely" | `sustained` |
| Total >= +3 | Escalate confidence to "Confirmed" | `escalated` |

Partial mitigations DEGRADE confidence. Dismissal requires at least one `-3` together with a total of `-6` or lower — nothing weaker reaches `invalidated`.

## Output schema

Every DA evaluation produces this exact JSON structure:

```json
{
  "da_phase": "attack | verify",
  "da_verdict": "invalidated | degraded | sustained | escalated",
  "da_total_score": "<number>",
  "da_dimensions": [
    {
      "dimension": "<dimension ID from table above>",
      "score": "<number: -3, -2, -1, 0, or +1>",
      "evidence": "<what was found or not found — concrete, not vague>",
      "code_references": ["<file:line>"]
    }
  ],
  "da_reasoning": "<1-2 sentence summary of the DA evaluation>"
}
```

Every `code_references` entry points at real code you opened with `read`, at the line you observed.

### VERIFY phase extension

In VERIFY, each dimension entry MAY include an additional field:

```json
{
  "attack_da_disagreement": "<null or explanation of why the VERIFY-DA disagrees with the ATTACK-DA score for this dimension>"
}
```

## Output format

Your ENTIRE response is valid JSON matching the Output Schema above — no markdown fences, no prose before or after.

## Completion criteria

- All 6 dimension IDs present in `da_dimensions`, each with a score from the closed set and a concrete `evidence` string.
- Every `code_references` entry resolves to a real file and line you read.
- `da_total_score` equals the arithmetic sum of the six scores.
- `da_verdict` follows from the decision-rules table given that total.
