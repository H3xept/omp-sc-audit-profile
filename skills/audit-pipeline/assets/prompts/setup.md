# SETUP — Static Analysis and Scope Definition

## Purpose

Run the static analysers, load the audit checklist manifest, persist full raw findings to disk, and return a concise summary. The raw artifacts on disk are what MAP consumes; the summary is what the orchestrator keeps in context.

## Lane discipline

This file defines your whole job. It outranks anything else visible to you: treat the dispatching prompt's named inputs as your only inputs, stay inside this phase, and return exactly the JSON in the Output Schema. This phase is data collection — security findings are produced later, by HUNT and ATTACK.

## Inputs

| Name | Type | Required | Description |
|:-----|:-----|:---------|:------------|
| `rootDir` | string | yes | Absolute path to the project root containing Solidity contracts |
| `scopeFiles` | string[] | no | Specific `.sol` files in scope. Empty means the whole project |

## Tools

`glob` to discover `.sol` files, `read` for config files and the checklist references, `bash` to run the analysers and create directories, `write` to persist raw findings under `.sc-audit/raw/`.

## Procedure

### Step 1 — Define scope

1. `glob` all `.sol` files under `rootDir`. Record the full list. When `scopeFiles` is non-empty, keep the full list for context and mark the scoped subset.
2. Determine the Solidity compiler version:
   - `foundry.toml` → `solc` or `solc_version`.
   - Otherwise `hardhat.config.ts` / `hardhat.config.js` → `solidity.version`.
   - Otherwise scan contract pragmas and take the most common `pragma solidity` version.
3. When `solc-select` is on PATH, run `solc-select use <version>`.

**Gate**: zero `.sol` files found → record the error in `warnings` and stop.

### Step 2 — Create the work directory

```bash
mkdir -p "<rootDir>/.sc-audit/raw" "<rootDir>/.sc-audit/checkpoints" "<rootDir>/.sc-audit/pocs"
```

### Step 3 — Run Slither

```bash
cd "<rootDir>" && slither . --json .sc-audit/raw/slither-findings.json
```

- Run it with the `bash` tool's `timeout: 300` (a 5-minute ceiling). Slither exits non-zero when it finds issues, so judge success by whether the JSON output file was created and parses.
- On success: `read` the JSON, filter results to in-scope files, count findings by severity, extract the top 20 sorted critical > high > medium > low > informational.
- On failure (binary missing, compilation error, timeout, unparseable JSON): record the error string, set `available = false`, and write `[]` to `.sc-audit/raw/slither-findings.json`.

### Step 4 — Run Aderyn

```bash
cd "<rootDir>" && aderyn . -o .sc-audit/raw/aderyn-findings.json
```

- Same `timeout: 300` ceiling, same success test, and same failure handling as Slither, writing `[]` to `.sc-audit/raw/aderyn-findings.json` on failure.
- On success: filter to in-scope files, count by severity, extract the top 20 sorted by severity.

### Step 5 — Dump storage layouts

```bash
cd "<rootDir>" && forge inspect <Contract> storage-layout --json
```

- Run once per in-scope contract — the scoped subset from Step 1, or every contract when `scopeFiles` is empty. Collect the results into `.sc-audit/raw/storage-layout.json`, keyed by `<file>:<contract>`.
- Same `timeout: 300` ceiling. A Hardhat project has no `forge inspect`: set `available = false` with that as the reason rather than improvising a substitute.
- Interfaces and libraries have no layout. Skip them; that is not an error.
- On failure write `{}`, set `available = false`, and record the error string. This artifact is what gives the `storage` and `upgrade` finding categories a mechanical basis — without it they rest on hand-tracing, so its absence is worth a warning.
- Do not judge the layout. SETUP collects slots, offsets, and byte widths; HUNT decides whether an arrangement is exploitable.
### Step 6 — Load the checklist manifest

The audit checklist is vendored at `skill://smart-contract-audit/references/`.

1. `read` `skill://smart-contract-audit/references/INDEX.md`. It lists every checklist category with its item count and reference file, then the protocol playbooks and the token catalog.
2. Select the categories that match the scope you found in Step 1 (for example: a vault protocol pulls `defi.md`, `token.md`, `basics.md`, `external-call.md`; a bridge pulls `multi-chain-cross-chain.md`, `signature.md`, `hash-merkle-tree.md`; anything behind a proxy pulls `upgradeability.md`).
3. Classify the protocol into every playbook type whose "Load when" line in INDEX matches the code. A router that swaps and bridges is both `amm-dex` and `aggregators-routers`. Record the playbooks in the manifest; their bug classes are the protocol-specific hypotheses HUNT works from.
4. Set `weird_erc20` to the catalog path when in-scope code moves an ERC-20 whose address is user-supplied, governance-listed, or an external dependency; set it to `null` when the only tokens are the protocol's own fixed contracts.
5. `write` `.sc-audit/raw/checklist.json` as the manifest downstream phases resolve against:

```json
{
  "index": "skill://smart-contract-audit/references/INDEX.md",
  "categories": [
    { "category": "<name from INDEX>", "file": "skill://smart-contract-audit/references/<file>.md", "item_count": "<number>", "in_scope": "<boolean>" }
  ],
  "playbooks": [
    { "type": "<playbook name from INDEX>", "file": "skill://smart-contract-audit/references/playbooks/<file>.md", "reason": "<code shape that matched>" }
  ],
  "weird_erc20": "skill://smart-contract-audit/references/weird-erc20.md | null",
  "total_items": "<number>"
}
```

Set `checklist.loaded = true`, `checklist.itemCount = total_items`, and `checklist.playbooks` to the playbook names. When `INDEX.md` is unreadable, write `{}`, set `loaded = false`, and add a warning.

### Step 7 — Evaluate tool availability

- BOTH analysers failed → warning `"Both Slither and Aderyn failed. Audit proceeds in manual-only mode."`
- ONE failed → warning `"<tool> failed: <error>. Continuing with <other_tool> and manual analysis."`

### Step 8 — Emit output

Return the `SetupSummary` JSON. `topFindings` caps at 20 per tool; the full arrays live only on disk.

## Output Schema — SetupSummary

```json
{
  "phase": "SETUP",
  "timestamp": "<ISO-8601>",
  "scope": {
    "rootDir": "<string>",
    "solidityFiles": ["<string>"],
    "solcVersion": "<string>",
    "totalSolFiles": "<number>"
  },
  "slither": {
    "available": "<boolean>",
    "error": "<string | null>",
    "findingCounts": {
      "critical": "<number>",
      "high": "<number>",
      "medium": "<number>",
      "low": "<number>",
      "informational": "<number>"
    },
    "topFindings": [
      {
        "detector_id": "<string>",
        "severity": "<string>",
        "title": "<string>",
        "affected_file": "<string>",
        "affected_line": "<number>"
      }
    ]
  },
  "aderyn": {
    "available": "<boolean>",
    "error": "<string | null>",
    "findingCounts": {
      "critical": "<number>",
      "high": "<number>",
      "medium": "<number>",
      "low": "<number>",
      "informational": "<number>"
    },
    "topFindings": [
      {
        "detector_id": "<string>",
        "severity": "<string>",
        "title": "<string>",
        "affected_file": "<string>",
        "affected_line": "<number>"
      }
    ]
  },
  "storageLayout": {
    "available": "<boolean>",
    "error": "<string | null>",
    "contractCount": "<number>",
    "path": ".sc-audit/raw/storage-layout.json"
  },
  "checklist": {
    "loaded": "<boolean>",
    "itemCount": "<number>",
    "playbooks": ["<string>"]
  },
  "warnings": ["<string>"]
}
```

## Output format

Your ENTIRE response is valid JSON matching the Output Schema above — no markdown fences, no prose before or after.

## Completion criteria

- `.sc-audit/raw/slither-findings.json`, `.sc-audit/raw/aderyn-findings.json`, `.sc-audit/raw/storage-layout.json`, and `.sc-audit/raw/checklist.json` all exist and parse as JSON (`[]` or `{}` where a tool failed).
- `scope.solcVersion` is a concrete version string or `"unknown"`.
- Every tool failure appears both as an `error` string on its object and as a `warnings` entry.
- Reading code happened only for scope detection (pragma and config scanning); source files and project configuration are unchanged.
