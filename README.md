# omp-sc-audit-profile

An [omp](https://github.com/can1357/oh-my-pi) profile for Solidity security work.
It carries the audit pipeline, the supporting skills, the custom subagents, and the
model routing they assume. Install it as an isolated profile, so it never touches
your everyday omp setup.

## Install

```bash
git clone git@github.com:H3xept/omp-sc-audit-profile.git
cd omp-sc-audit-profile
./install.sh
```

`install.sh` copies the profile into `~/.omp/profiles/audit/agent/` and seeds
`.env` and `mcp.json` from the `.example` files on first run. Fill in your own
keys, then run once:

```bash
omp --profile=audit --alias=audit
```

That creates a shell shortcut, so later sessions start with `audit` instead of
the full flag. To update, `git pull && ./install.sh`. The script uses
`rsync --delete`, so a prompt removed upstream is removed locally too. Your
`.env`, `mcp.json` and session history are excluded from deletion.

Set `OMP_PROFILE_NAME` to install under a different profile name.

## Prerequisites

### Credentials

| Variable | Used for |
| --- | --- |
| `OPENROUTER_API_KEY` | Every `openrouter/` model role in `config.yml` |
| `EXA_API_KEY` | First entry in `providers.webSearchOrder` |
| `ETHERSCAN_API_KEY` | Recon lookups, and the Etherscan MCP server in `mcp.json` |

Two routes do not use OpenRouter:

- `task: anthropic/claude-opus-5:high`, plus the `reviewer`,
  `security-reviewer` and `invariant-engineer` agent overrides. These need
  Anthropic auth in omp.
- `plan-critic: openai-codex/gpt-5.6-sol:high`. This needs the `openai-codex`
  provider, which authenticates against a ChatGPT subscription. Without it,
  repoint `task.agentModelOverrides.plan-critic` in `config.yml` at a model you
  do have.

### Binaries

The skills shell out to these. The pipeline degrades gracefully when one is
missing — a scanner lane writes empty findings and warns — but the audit is
materially weaker, so install them all.

| Tool | Install |
| --- | --- |
| `forge`, `cast` | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| `slither` | `pipx install slither-analyzer` |
| `aderyn` | `cargo install aderyn` |
| `echidna` | `brew install echidna` |
| `medusa` | `go install github.com/crytic/medusa@latest` |
| `halmos` | `pipx install halmos` |

`lsp.json` configures only `tsgo` and `typescript-language-server`. There is no
Solidity language server, so expect no Solidity diagnostics or rename support.
The pipeline relies on `forge` and the scanners instead.

## What is in here

### Skills

| Skill | Role |
| --- | --- |
| `audit-pipeline` | The orchestrator. Phased audit with per-phase prompts under `assets/prompts/` |
| `smart-contract-audit` | Checklist- and playbook-driven review: the vendored Cyfrin `SOL-` checklist plus profile `AUD-` categories, protocol playbooks, methodology, and the weird-ERC20 catalog under `references/` |
| `recon-suite` | Static analysis and surface mapping: slither, aderyn, storage layout |
| `fuzz-echidna-medusa` | Property fuzzing setup and campaign running, with a per-protocol property catalog under `references/` |
| `halmos-verify` | Symbolic verification of bounded properties |
| `test-foundry` | Foundry test suite generation, including fuzz and invariant tests; exploit PoC templates per bug class under `references/` |
| `onchain-forensics` | Deployed-contract inspection: proxy state, bytecode-vs-build diffing, on-chain role enumeration, incident transaction analysis. Ships `cast`-based scripts |
| `gas-optimize` | Gas analysis with snapshot-backed before/after numbers |
| `exec-plan` | Writes the self-contained execution plan for a change |
| `refine-plan` | Audits an execution plan for gaps and dead references |

### Subagents

| Agent | Role |
| --- | --- |
| `invariant-engineer` | Derives and encodes protocol invariants |
| `fuzz-triage` | Turns fuzz counterexamples into minimal reproductions |
| `plan-critic` | Adversarial review of plans and findings |

### Other files

- `AGENTS.md` — the profile's standing instructions, including the
  `.sc-audit/` work-directory convention and the `SYSTEM.md` architecture brain.
- `config.yml` — model roles, agent overrides, skill filtering, retry chains.
- `lsp.json` — language server configuration.

## What stays on your machine

`.env` and `mcp.json` hold credentials and are gitignored. So are
`sessions/`, `terminal-sessions/`, `cache/` and the `*.db` state files, which
hold your own session transcripts and history. Only commit prompts and config.

## License

The vendored Solidity checklist under `skills/smart-contract-audit/` is MIT
licensed; its `LICENSE` file travels with it. Everything else in this repo is
internal tooling.
