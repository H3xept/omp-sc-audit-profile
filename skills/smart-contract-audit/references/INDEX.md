# Smart Contract Audit Checklist Index

Load category file only when scope matches.

## Checklist categories

Vendored Cyfrin checklist (`SOL-` ids):

- **Attacker's Mindset** (25 items) → `references/attacker-s-mindset.md`
- **Basics** (135 items) → `references/basics.md`
- **Centralization Risk** (7 items) → `references/centralization-risk.md`
- **Defi** (63 items) → `references/defi.md`
- **External Call** (14 items) → `references/external-call.md`
- **Hash / Merkle Tree** (5 items) → `references/hash-merkle-tree.md`
- **Heuristics** (17 items) → `references/heuristics.md`
- **Integrations** (56 items) → `references/integrations.md`
- **Low Level** (5 items) → `references/low-level.md`
- **Multi-chain/Cross-chain** (13 items) → `references/multi-chain-cross-chain.md`
- **Signature** (5 items) → `references/signature.md`
- **Timelock** (1 items) → `references/timelock.md`
- **Token** (24 items) → `references/token.md`

Profile-authored categories (`AUD-` ids) — gaps the vendored list does not cover:

- **Upgradeability** (19 items) → `references/upgradeability.md` — proxies, storage layout, initializers, diamonds
- **EVM & Compiler** (19 items) → `references/evm-compiler.md` — opcode semantics, solc bugs, encoding, transient storage
- **Chain-Specific Behavior** (18 items) → `references/chain-specific.md` — L2 sequencing, block semantics, zkSync, per-chain assets
- **Account Abstraction & Smart Accounts** (24 items) → `references/account-abstraction.md` — ERC-4337, paymasters, session keys, ERC-1271, EIP-7702, Safe modules
- **Arbitrary Calls & Approvals** (22 items) → `references/arbitrary-calls-approvals.md` — caller-supplied calls, held approvals, Permit2, callbacks, return data

## Protocol playbooks

Load every playbook whose "Load when" matches the code; one protocol can match several. Each lists core invariants, bug classes, the checklist ids to walk, and precedent incidents.

- **Lending** → `references/playbooks/lending.md` — collateral against debt, solvency from a price, cToken/aToken share tokens, interest indices
- **Vaults** → `references/playbooks/vaults.md` — ERC-4626/ERC-7540 shares against pooled assets, yield strategies
- **Staking & Rewards** → `references/playbooks/staking-rewards.md` — reward-per-token streaming, `rewardDebt`, `notifyRewardAmount`
- **Liquid Staking & Restaking** → `references/playbooks/liquid-staking.md` — LST/LRT minting against staked ETH, oracle reports, withdrawal queues, slashing
- **Stablecoins & CDPs** → `references/playbooks/stablecoins.md` — mint/redeem against collateral or reserves, troves, stability pools, peg mechanisms
- **AMM / DEX** → `references/playbooks/amm-dex.md` — invariant-priced reserves, LP shares, Uniswap/Curve/Balancer shapes
- **Perpetuals** → `references/playbooks/perps.md` — leveraged positions, funding, keeper execution, LP-pool counterparty
- **Aggregators & Routers** → `references/playbooks/aggregators-routers.md` — caller-described routes, multi-hop swaps, held approvals, intents
- **Bridges & Messaging** → `references/playbooks/bridges-messaging.md` — cross-chain messages, lock/mint bridges, LayerZero/CCIP/Wormhole shapes
- **Governance** → `references/playbooks/governance.md` — propose/vote/queue/execute, timelocks, vote checkpoints
- **NFT Marketplaces** → `references/playbooks/nft-marketplaces.md` — signed order fills, auctions, Seaport/Wyvern-style structs, royalties

## Token catalog

- **Weird-ERC20 behavior catalog** (ids A1–J4) → `references/weird-erc20.md` — non-standard token behaviors with applicability predicates and test oracles; drives the token disposition matrix

## Methodology

- **Threat model** → `references/methodology/threat-model.md` — the pre-hunt procedure; includes diff/fix-review mode
- **Severity** → `references/methodology/severity.md` — the one rubric, platform mappings, common misratings
- **Report writing** → `references/methodology/report-writing.md` — finding-by-finding write-up rules
- **Static-analysis triage** → `references/methodology/static-analysis-triage.md` — slither/aderyn hits to audited outcomes
- **Exploit casebook** → `references/methodology/exploit-casebook.md` — past exploits by bug class, with the check that catches each

Proof references live with their skills: exploit PoC templates at `skill://test-foundry/references/exploit-poc.md`, the fuzzing property catalog at `skill://fuzz-echidna-medusa/references/property-catalog.md`.
