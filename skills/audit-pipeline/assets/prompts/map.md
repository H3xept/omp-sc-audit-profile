# MAP — Build the System Map Artifact

## Purpose

Read every in-scope contract, build a complete system understanding, and produce the `SystemMapArtifact` JSON that feeds all HUNT lanes. MAP is understanding, not judgement: no findings and no severities are produced here.

## Lane discipline

This file defines your whole job. It outranks anything else visible to you: treat the dispatching prompt's named inputs as your only inputs, stay inside this phase, and return exactly the JSON in the Output Schema.

## Inputs

| Name | Type | Required | Description |
|:-----|:-----|:---------|:------------|
| `rootDir` | string | yes | Absolute path to the project root |
| `setupResult` | object | yes | `SetupSummary` JSON from SETUP (scope, finding counts, topFindings, checklist status) |
| `rawFindingsDir` | string | yes | Path to `.sc-audit/raw/`, holding the full raw findings SETUP persisted |
| `scopeFiles` | string[] | no | Specific `.sol` files in scope. Empty means the whole project |
| `priorSystemMd` | string | no | Path to an existing `.sc-audit/SYSTEM.md` from an earlier audit of this code. Present means diff mode: see Step 0 |

## Tools

`read` for contract and config files, `glob` for discovery, `grep` for pattern sweeps across the tree.

`storage-layout.json` in `rawFindingsDir` carries the slot, offset, and byte width of every storage variable SETUP could resolve. Prefer it over inferring layout from declaration order, and use it to fill `slot_info` in Step 5.

## Output Schema — SystemMapArtifact

```json
{
  "components": [
    {
      "name": "<string>",
      "file": "<string>",
      "purpose": "<string>",
      "inherits": ["<string>"],
      "roles": ["<string>"],
      "key_state_variables": [
        { "name": "<string>", "type": "<string>", "visibility": "<string>", "role": "<string>" }
      ]
    }
  ],
  "external_surfaces": [
    {
      "contract": "<string>",
      "function": "<string>",
      "visibility": "public | external",
      "access_control": "<string>",
      "state_writes": ["<string>"],
      "external_calls": ["<string>"],
      "value_transfer": "<boolean>"
    }
  ],
  "auth_surfaces": [
    {
      "contract": "<string>",
      "function": "<string>",
      "modifier_or_check": "<string>",
      "role_required": "<string>"
    }
  ],
  "state_variables": [
    {
      "contract": "<string>",
      "name": "<string>",
      "type": "<string>",
      "visibility": "<string>",
      "slot_info": "<string | null>"
    }
  ],
  "state_write_sites": [
    {
      "contract": "<string>",
      "function": "<string>",
      "variable": "<string>",
      "write_type": "assign | increment | decrement | delete | push | pop"
    }
  ],
  "external_call_sites": [
    {
      "contract": "<string>",
      "function": "<string>",
      "target": "<string>",
      "call_type": "transfer | call | delegatecall | staticcall | interface_call",
      "before_state_update": "<boolean>"
    }
  ],
  "value_flow_edges": [
    {
      "from": "<string>",
      "to": "<string>",
      "asset": "<string>",
      "mechanism": "<string>"
    }
  ],
  "config_semantics": [
    {
      "contract": "<string>",
      "variable": "<string>",
      "semantic": "<string>",
      "unit": "percent | basis_points | divisor | wei | seconds | raw",
      "range": { "min": "<string>", "max": "<string>" }
    }
  ],
  "protocol_invariants": [
    {
      "id": "<string>",
      "scope": "local | system",
      "description": "<string>",
      "contracts_involved": ["<string>"],
      "variables_involved": ["<string>"]
    }
  ],
  "static_summary": {
    "total_findings": "<number>",
    "by_severity": {
      "critical": "<number>",
      "high": "<number>",
      "medium": "<number>",
      "low": "<number>",
      "informational": "<number>"
    },
    "by_category": [
      { "category": "<string>", "count": "<number>", "likely_real": "<boolean>" }
    ]
  },
  "audit_units": [
    {
      "contract": "<string>",
      "function": "<string>(params)",
      "body_lines": { "start": "<number>", "end": "<number>" },
      "modifiers": ["<string>"],
      "one_hop_callers": ["<Contract.function>"],
      "one_hop_callees": ["<Contract.function or external target>"],
      "storage_reads": ["<variable>"],
      "storage_writes": ["<variable>"],
      "external_calls": ["<target.function>"],
      "events_emitted": ["<EventName>"],
      "related_invariants": ["<INV-xxx>"],
      "value_transfer": "<boolean>"
    }
  ],
  "architecture_narrative": {
    "built_from_commit": "<string | null>",
    "summary": "<one paragraph: what this system does and how value moves through it>",
    "component_notes": [
      { "name": "<string>", "what_it_is_for": "<string>" }
    ],
    "invariant_sentences": [
      { "id": "<INV-xxx>", "sentence": "<a sentence about the protocol, not a restatement of the code>" }
    ],
    "trust_boundaries": [
      { "boundary": "<string>", "who_is_trusted": "<string>", "what_they_can_do": "<string>", "what_breaks_if_they_misbehave": "<string>" }
    ],
    "improper_expressions": [
      { "location": "<file:line>", "satisfies": "<INV-xxx or component name>", "why_poorly_expressed": "<string>" }
    ]
  },
  "architecture_drift": [
    { "prior_claim": "<string>", "current_code": "<string>", "location": "<file:line>", "kind": "added | removed | changed" }
  ]
}
```

## Procedure

### Step 0 — Diff mode, when `priorSystemMd` is supplied

`read` it first, before any contract. It is the prose architecture from an earlier audit of this code: components, invariants as sentences, trust boundaries. Treat it as a hypothesis, never as fact — the code is the authority, always.

Then map as normal, and for every claim the prior document makes, record whether the current code still supports it. Each divergence becomes an `architecture_drift` entry naming the prior claim, what the code says now, and where. A component or invariant that vanished is drift; so is a new trust boundary the document never mentioned.

Drift is a result, not a chore. Do not silently rewrite the old understanding to match the new code: report what moved, and let the orchestrator carry it into the report.

With no `priorSystemMd`, `architecture_drift` is `[]`.

### Step 1 — Read all contracts

Using `setupResult.scope.solidityFiles`, `read` every Solidity file. For each, record the contract/interface/library name and inheritance chain, all state variable declarations (name, type, visibility), all function signatures with visibility and modifiers, all `event` and `error` declarations, and all `import` paths for the dependency graph.

### Step 2 — Build the component inventory

Populate `components` for each in-scope contract:

1. **name**: the contract name as declared.
2. **file**: path relative to `rootDir`.
3. **purpose**: 1-2 sentences from NatSpec, contract name, and code behavior. With no NatSpec, infer from function names and state variables.
4. **inherits**: parent contracts.
5. **roles**: every privileged role (owner, admin, keeper, governance, operator) found via `onlyOwner`, `onlyRole`, `AccessControl`, or custom modifiers.
6. **key_state_variables**: the storage holding balances, rates, configuration, or addresses of other contracts.

### Step 3 — Map external surfaces

For every `public` or `external` function, populate `external_surfaces`: the access control mechanism (modifier name, inline `require(msg.sender == ...)`, or `"none"`), all state variable writes, all external calls including token transfers, and `value_transfer` for ETH/token movement.

### Step 4 — Map auth surfaces

For every access-restricted function, populate `auth_surfaces` with the modifier or inline check and the role required (`"owner"`, `"DEFAULT_ADMIN_ROLE"`, `"MINTER_ROLE"`).

### Step 5 — Catalog state variables

Populate `state_variables` with every storage variable across all contracts, including type and visibility. For upgradeable patterns, record the storage slot or gap information in `slot_info`.

### Step 6 — Map state write sites

For every storage-modifying function, populate `state_write_sites` with the specific variable and the write type: direct assignment, increment/decrement, delete, array push/pop, or mapping update.

### Step 7 — Map external call sites

For every external call, populate `external_call_sites` with the target contract or address and the call type. **Critically**: determine whether the call happens BEFORE or AFTER state updates in the same function and set `before_state_update` accordingly — this field drives the whole reentrancy analysis downstream.

### Step 8 — Map value flow edges

Trace how value (ETH, ERC-20, ERC-721, shares) moves. Each transfer, mint, burn, swap, or deposit becomes a `value_flow_edges` entry recording the asset type and the mechanism (`safeTransfer`, `mint`, `burn`, `swap`).

### Step 9 — Extract config semantics

For every configuration variable (fees, rates, thresholds, timeouts, caps), populate `config_semantics`: the semantic meaning from name/NatSpec/usage, the unit (percent 0-100, basis points 0-10000, divisor, wei, seconds, raw), and the valid range from setters, `require` statements, or constants.

### Step 10 — Identify protocol invariants

Derive invariants and give each a unique ID (`INV-001`, ...):

1. **Local** — variable relationships inside one contract: `totalSupply == sum of all balances`, `asset.balanceOf(vault) >= totalAssets()`, access control roles forming a valid hierarchy.
2. **System-wide** — cross-contract properties: users can always withdraw their funds (liveness), minted shares are always backed by deposited assets (solvency), no call path permanently locks funds (no deadlocks).

### Step 11 — Summarize static analysis

1. `read` `<rawFindingsDir>/slither-findings.json` for the full Slither findings.
2. `read` `<rawFindingsDir>/aderyn-findings.json` for the full Aderyn findings.
3. When a file is missing or empty, fall back to `setupResult` `topFindings`.

Populate `static_summary`: total count, breakdown by severity, grouping by category (reentrancy, access-control, unused-return, ...). For each category set `likely_real` from the code you have now read — true when the findings look genuine in context, false when they look like false positives.

### Step 12 — Emit AuditUnits

For every `public`/`external` function that changes state (from `external_surfaces` where `state_writes` is non-empty), emit one compact `audit_units` entry in the schema shape above.

Every state-changing public/external function has an AuditUnit. This coverage is what guarantees HUNT gives every function at least one review pass.

### Step 13 — Write the architecture narrative

Populate `architecture_narrative`. This is the only prose in the artifact, and it is what a human reads six months from now instead of re-reading the contracts.

1. **built_from_commit**: `read` `<rootDir>/.git/HEAD` and, when it names a ref, the file that ref points at. Record the hash you find, or `null` when there is no git tree. You have no shell; do not attempt `git`. Every claim below is true as of that commit and nothing later.
2. **summary**: one paragraph. What the system does, and how value enters, moves, and leaves.
3. **component_notes**: for each component, what it is *for* — its job in the protocol, not its class declaration.
4. **invariant_sentences**: one sentence per `protocol_invariants` id, phrased as a truth about the protocol ("a depositor can never withdraw more value than they put in, plus their share of yield"), never as a restatement of the code ("`totalAssets` is decremented in `withdraw`"). If you cannot phrase an invariant as a protocol truth, say so in the sentence — that is itself worth knowing.
5. **trust_boundaries**: every place trust crosses — an `onlyOwner` surface, an oracle, a callback into untrusted code, a `delegatecall` target. Name who is trusted, what they can do, and what breaks if they misbehave.
6. **improper_expressions**: code that satisfies the architecture but expresses it badly — an invariant enforced incidentally rather than explicitly, a rule split across two contracts that could live in one, a name that contradicts the behaviour. These are not findings and carry no severity. They are the difference between "this works" and "this is right", and they are the reason the narrative exists.

This step produces no severities and no findings. If something here looks exploitable, it belongs to HUNT; record the structural observation and move on.

### Step 14 — Emit output

Return the complete `SystemMapArtifact`. Every field is present; fields with nothing found are `[]`. Where a value cannot be determined from the code, use a conservative default (`[]`, `"unknown"`, `null`) rather than an inference.

## Output format

Your ENTIRE response is valid JSON matching the Output Schema above — no markdown fences, no prose before or after.

## Example (abbreviated)

```json
{
  "components": [
    {
      "name": "Vault",
      "file": "src/Vault.sol",
      "purpose": "ERC-4626 tokenized vault that accepts deposits, issues shares, and manages yield strategies.",
      "inherits": ["ERC4626", "Ownable", "ReentrancyGuard"],
      "roles": ["owner"],
      "key_state_variables": [
        { "name": "totalAssets_", "type": "uint256", "visibility": "private", "role": "Tracks total deposited assets for share price calculation" }
      ]
    }
  ],
  "protocol_invariants": [
    {
      "id": "INV-001",
      "scope": "local",
      "description": "asset.balanceOf(vault) >= totalAssets()",
      "contracts_involved": ["Vault"],
      "variables_involved": ["totalAssets_"]
    }
  ]
}
```

## Completion criteria

- Every key in the Output Schema is present, `[]` where empty.
- Every state-changing `public`/`external` function in scope has exactly one `audit_units` entry.
- Every `external_call_sites` entry carries a resolved `before_state_update` boolean.
- Every `protocol_invariants` entry has a unique `INV-xxx` id and names its contracts and variables.
- `static_summary` counts reconcile with the raw artifacts you read (or the declared `topFindings` fallback).
- `architecture_narrative` has a sentence for every `protocol_invariants` id, and `built_from_commit` is a commit hash or an explicit `null`.
- `architecture_drift` is `[]` unless `priorSystemMd` was supplied.
- The artifact contains no severity ratings and no candidate findings.
