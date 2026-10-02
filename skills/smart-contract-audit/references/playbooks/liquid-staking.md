# Liquid staking and restaking playbook

Load when: the code mints a token against staked ETH or staked/restaked assets: beacon deposit contract calls (`deposit(pubkey, withdrawal_credentials, signature, deposit_data_root)`), validator/operator registries, oracle balance reports, withdrawal queues (`requestWithdrawal`/`claim`/unstETH-style NFTs), EigenLayer `StrategyManager`/`DelegationManager`/`EigenPod` calls, or an LRT whose price is computed from a basket of LSTs.

## Core invariants

1. `exchangeRate = totalPooledAssets / totalShares`, where `totalPooledAssets` counts every location exactly once: buffer, in-flight beacon deposits, consensus-layer balances (from oracle), withdrawal vault, restaking strategies, queued withdrawals, minus ETH already reserved for finalized withdrawals.
2. The exchange rate moves only through an oracle report, a fee mint, or a slashing/penalty report; deposits and withdrawals leave it unchanged (within rounding in the protocol's favor).
3. A single oracle report moves the rate by no more than a configured bound, and the report cannot be replayed or applied out of order.
4. Every validator the protocol funds has the protocol's withdrawal credentials, and the protocol funds no pubkey whose credentials were set by someone else.
5. A withdrawal request never pays more than the value of its shares at request time, and losses that land before finalization reduce what it pays.
6. Restaked positions remain slashable until withdrawal completion; the LRT values queued withdrawals net of slashing that can still be applied.
7. Minting and redeeming at the protocol rate cannot be combined with a market or oracle rate in one transaction for risk-free profit larger than fees.
8. Operator and validator registries keep a one-to-one mapping between keys and indices across add, remove, and reorder operations.

## Where value moves

- **Entry:** `submit`/`deposit`/`depositETH`/`depositAsset(lst, amount)`, referral or zap deposits, direct ETH sends to `receive`, MEV/execution-layer rewards into a vault, consensus rewards via withdrawals to the withdrawal credentials address.
- **Exit:** `requestWithdrawal` then `claim`, instant-withdraw pools, DEX liquidity for the LST/LRT, EigenLayer `queueWithdrawals` then `completeQueuedWithdrawals`, fee mints to treasury and node operators, operator bond refunds.
- **Privileged parameters:** oracle members and quorum, report sanity bounds, fee splits, operator onboarding and key limits, deposit/withdrawal pause, LST whitelist and per-asset caps for LRTs, operator delegation targets, upgrade keys.
- **External dependencies:** beacon deposit contract, consensus-layer oracle committee, EigenLayer (or another restaking layer) slashing and delays, Chainlink or protocol-native rates for each LST in an LRT basket, DEX liquidity used by integrators to price the token.

Build a ledger table: every place pooled ETH or assets can sit, the variable that tracks it, the function that moves value in or out of that place, and whether `totalPooledAssets` reads it. Missing or doubled rows are first-priority findings.

## Bug classes

### Withdrawal-credential front-running
- **Mechanism:** the first deposit for a pubkey binds its withdrawal credentials. A malicious node operator deposits 1 ETH for the same pubkey with credentials they control just before the protocol's 32 ETH deposit; the protocol's deposit then funds a validator the operator owns.
- **Where to look:** the function that submits protocol deposits, any check against the deposit contract root at submission time, operator-supplied pubkeys and signatures.
- **Ask:** what prevents an operator-supplied pubkey from having been pre-deposited with foreign credentials between key submission and protocol deposit?
- **Prove:** fork test: operator pre-deposits for the pubkey with alternate credentials, then the protocol deposit executes; assert the protocol has no guard (Lido's mitigation: the Deposit Security Committee signs the current deposit root and the deposit reverts if it changed).

### Rate-update sandwich
- **Mechanism:** the rate jumps at a known oracle report. An attacker deposits before a positive report and redeems after, or exits through instant liquidity before a negative (slashing) report. Instant-withdraw pools and LRT deposit/withdraw at oracle rates make this a same-block trade.
- **Where to look:** oracle report transaction (mempool-visible), instant-withdrawal paths, deposit cooldowns, withdrawal delays, rate smoothing.
- **Ask:** is there any path that buys at the pre-report rate and sells at the post-report rate within a window shorter than the report cadence?
- **Prove:** PoC: deposit, apply oracle report with +X%, instant-redeem; assert profit > fees. For negative reports: request exit before the slash report and show the request settles at the pre-slash rate.

### Withdrawal queue pricing and finalization
- **Mechanism:** the request fixes an amount at the request-time rate, and slashing that lands before finalization is not passed on, so remaining holders absorb it; or finalization uses an arbitrary rate supplied by a privileged or permissionless caller; or claims are not bound to the finalized batch.
- **Where to look:** `requestWithdrawal` (what is stored: shares or assets), `finalize(lastId, maxShareRate)`, claim math, request NFT transfer hooks. Lido pays at most the requested amount and less when the share rate fell before finalization; it slows finalization (bunker mode) under mass slashing.
- **Ask:** which rate does a claim use, who supplies it, and does a loss between request and finalization reduce the claim?
- **Prove:** stateful test: request, report a slashing loss, finalize, claim; assert claim value <= min(request-time value, finalization-time value).

### Asset accounting across locations
- **Mechanism:** ETH counted twice while in transit (buffer and pending deposits both include it), or not at all (rewards in the withdrawal vault before sweep, balances in deprecated strategies or node delegators), so the rate is wrong and minting or redeeming at it moves value.
- **Where to look:** `getTotalPooledEther`/`getTotalAssetDeposits` and every term in it; how strategy or node-delegator lists are iterated; EigenPod balance and queued-withdrawal shares.
- **Ask:** for each transition (deposit to beacon, reward sweep, strategy switch, queue withdrawal, complete withdrawal), does `totalPooledAssets` stay constant (or move by exactly the realized gain/loss)?
- **Prove:** stateful fuzz with a handler per transition; invariant 1 checked against an independent sum of balances.

### LRT basket pricing
- **Mechanism:** the LRT price is `sum(balance_i * price_i) / supply` across several LSTs. Each LST price has a deviation band (Chainlink) or a protocol rate that lags the market, so an attacker deposits the overpriced LST and withdraws the underpriced one. Balance-based totals also allow donation to move the price, and an empty LRT is open to first-depositor inflation.
- **Where to look:** price aggregation, per-asset oracle choice (market vs exchange-rate), `balanceOf`-based totals, deposit/withdraw asset choice, minimum mint amounts.
- **Ask:** can a user choose which asset to enter and exit with, and does each asset's price source move independently?
- **Prove:** PoC with two mock LST oracles each moved within its allowed deviation; deposit A, withdraw B; assert profit. For donation: transfer an LST to the deposit pool and compare the LRT price before and after.

### Restaking slashing propagation
- **Mechanism:** on EigenLayer, slashing reduces an operator's magnitude for an operator set and applies to queued withdrawals at completion. An LRT that values queued withdrawals at their queued share count, or caches strategy shares, overstates assets after a slash and lets holders exit at the pre-slash rate. Allocation and deallocation delays create windows where new stake is not yet slashable or old stake still is.
- **Where to look:** how the LRT reads `withdrawableShares` vs deposit shares, queued-withdrawal bookkeeping, delegation changes (undelegate queues all shares), operator allocation config.
- **Ask:** after `slashOperator`, which LRT functions still return pre-slash values, and for how long?
- **Prove:** fork test against EigenLayer core: deposit through the LRT, queue a withdrawal, slash the operator set, complete; compare the LRT's reported assets with the received amount. Reference values: `DEALLOCATION_DELAY` and the minimum withdrawal delay are 100,800 blocks (~14 days); `ALLOCATION_CONFIGURATION_DELAY` is 126,000 blocks (~17.5 days).

### Oracle report integrity
- **Mechanism:** reports accepted below quorum, replayed, applied for an older reference slot, or unbounded so one compromised member moves the rate arbitrarily; proof-of-reserves feeds stale while the protocol keeps minting.
- **Where to look:** report submission and consensus code, `refSlot`/epoch checks, sanity limits on APR and on balance decrease, staleness checks on reserve feeds.
- **Ask:** what is the maximum rate change one report can apply, and what does a stale or missing report do to minting?
- **Prove:** unit test submitting a report with an old reference slot and one exceeding the bound; both must revert. Rocket Pool's RPIP-61 is a reference bound: a capped rETH rate delta per update plus a minimum interval between updates.

### Registry and operator bookkeeping
- **Mechanism:** swap-and-pop removal leaves a moved operator's index stale in another mapping; duplicate pubkeys accepted; loops over all operators or validators exceed the gas limit as the set grows; a removed operator keeps its fee share.
- **Where to look:** `addOperator`/`removeOperator`/`addKeys`, `keysUsed`/`totalKeys` counters, deposit allocation loops.
- **Ask:** after every remove or reorder, does each mapping still agree on the operator for each index?
- **Prove:** stateful fuzz over add/remove/reorder with invariant 8; gas test of the allocation loop at the maximum operator count.

### Native ETH and NFT callbacks
- **Mechanism:** claim sends ETH with `call` before marking the request claimed, or mints an ERC-721 request with `_safeMint`, giving the receiver a reentry point into deposit/withdraw while the rate is mid-update.
- **Where to look:** `claim`, `claimWithdrawals`, unstake NFTs, `receive` functions in node delegators.
- **Ask:** what state is final before each ETH send or `onERC721Received` callback?
- **Prove:** PoC with a receiver contract that reenters `deposit` from `receive` and compares the rate it gets to the post-call rate.

### Integrating an LST or LRT
- **Mechanism:** stETH rebases and transfers 1–2 wei less than requested; rETH and cbETH rates come from protocol oracles with update lag; LRT liquidity is thin before native withdrawals open, so DEX prices depeg and liquidations cascade in lending markets that price it at market (Renzo ezETH).
- **Where to look:** the integrator's price source (market vs exchange rate vs hybrid), whether it uses wstETH or `transferShares`, liquidation thresholds for LRT collateral.
- **Ask:** if the token trades 20% below its redemption value for an hour, what does the integration do?
- **Prove:** fork test that pushes the DEX price down and checks liquidations against the protocol rate; see the [lending playbook](skill://smart-contract-audit/references/playbooks/lending.md) for the oracle bug class.

### Fee mint on the wrong base
- **Mechanism:** the protocol fee is minted as shares on "rewards" computed as `newBalance - oldBalance`; principal returned by validator exits, ETH arriving for withdrawals, or a donation is counted as reward and charged a fee, and a negative report followed by recovery charges the fee twice on the same ETH.
- **Where to look:** report handler fee calculation, the reward vs principal split for withdrawals arriving at the credentials address, high-water marks across negative reports, fee share mint ordering relative to the rate update.
- **Ask:** across a slash-then-recover sequence and a full validator exit, what fee does the protocol mint, and what should it mint?
- **Prove:** unit test: report a loss, then a gain of the same size; assert zero fee minted. Report a 32 ETH exit; assert fee minted only on the reward part.

### Rate relayed to other chains
- **Mechanism:** an LST or LRT minted on an L2 or another chain at a rate relayed from L1; the relay lags, so minting at the stale rate and redeeming or selling at the fresh rate is arbitrage, and a relay with no bound accepts any rate a compromised messenger sends.
- **Where to look:** cross-chain rate receivers, staleness and deviation checks, L2 deposit pools that mint against bridged ETH.
- **Ask:** what is the maximum age and maximum jump of the rate a remote minter accepts?
- **Prove:** test: deliver an old rate after a newer one; assert revert. See the [bridges and messaging playbook](skill://smart-contract-audit/references/playbooks/bridges-messaging.md).

## Checklist items to walk

- Liquid staking: SOL-Defi-LSD-1, SOL-Defi-LSD-2, SOL-Defi-LSD-3, SOL-Defi-LSD-4, SOL-Defi-LSD-5, SOL-Defi-LSD-6, SOL-Defi-LSD-7, SOL-Defi-LSD-8, SOL-Defi-LSD-9
- LST integrations: SOL-Integrations-LSD-stETH-1, SOL-Integrations-LSD-stETH-2, SOL-Integrations-LSD-stETH-3, SOL-Integrations-LSD-rETH-1, SOL-Integrations-LSD-rETH-2, SOL-Integrations-LSD-rETH-3, SOL-Integrations-LSD-rETH-4, SOL-Integrations-LSD-rETH-5, SOL-Integrations-LSD-cbETH-1, SOL-Integrations-LSD-cbETH-2, SOL-Integrations-LSD-sfrxETH-1, SOL-Integrations-LSD-sfrxETH-2
- Oracles: SOL-Defi-Oracle-3, SOL-Defi-Oracle-7, SOL-Defi-Oracle-10, SOL-Defi-Oracle-12, SOL-Defi-Oracle-14, SOL-Defi-General-5
- Shares and donations: SOL-Defi-General-3, SOL-Defi-General-4, SOL-AM-DA-1, SOL-Defi-FlashLoan-2
- Timing: SOL-AM-FrA-2, SOL-AM-SandwichAttack-1, SOL-Defi-General-8
- Liveness: SOL-AM-DOSA-1, SOL-AM-DOSA-4, SOL-AM-DOSA-6, SOL-Basics-AL-4, SOL-Basics-AL-9, SOL-Basics-AL-10
- Reentrancy and ETH: SOL-EC-1, SOL-EC-13, SOL-AM-ReentrancyAttack-1, SOL-Heuristics-14, SOL-Basics-Payment-1
- Math: SOL-Basics-Math-4, SOL-Basics-Math-5, SOL-Heuristics-10
- Admin and keys: SOL-CR-2, SOL-CR-4, SOL-CR-7, SOL-Timelock-1
- Token behavior: weird-ERC20 catalog ids B3, B4, B6, F4 in [weird-erc20](skill://smart-contract-audit/references/weird-erc20.md).
- Whole categories: [upgradeability](skill://smart-contract-audit/references/upgradeability.md) (proxy-held LSTs and LRTs), [chain-specific](skill://smart-contract-audit/references/chain-specific.md) (bridged LST rates on L2s), [arbitrary calls and approvals](skill://smart-contract-audit/references/arbitrary-calls-approvals.md) (node delegator `execute` hooks).

Proof tooling: [exploit PoC](skill://test-foundry/references/exploit-poc.md), [property catalog](skill://fuzz-echidna-medusa/references/property-catalog.md).

## Precedent

- **Lido and Rocket Pool deposit front-running, disclosed Oct 2021.** An operator could pre-deposit 1 ETH with its own withdrawal credentials for a pubkey the protocol was about to fund; Lido's LIP-5 added Deposit Security Committee signatures over the deposit root. https://blog.lido.fi/vulnerability-response-update/ ; https://research.lido.fi/t/lip-5-mitigations-for-deposit-front-running-vulnerability/1269 ; https://immunefi.com/blog/bug-fix-reviews/rocketpool-and-lido-frontrunning-bugfix-review/
- **Ankr aBNBc, Dec 2022.** A compromised deployer key upgraded the token proxy to add an unrestricted mint; the attacker minted a vast supply and sold it into DEX pools, and lending markets that priced aBNBc were hit. https://www.ankr.com/blog/the-abnbc-token-report/
- **Renzo ezETH depeg, Apr 2024.** With native withdrawals not yet enabled, ezETH crashed on DEXs and lending markets pricing it at market liquidated positions. https://www.dlnews.com/articles/defi/renzos-ezeth-loses-ether-peg-drops-79-in-under-one-hour/
- **Kelp rsETH, Code4rena Nov 2023.** Findings on basket-price arbitrage within Chainlink deviation bands (#584), donation price manipulation (#451), first-depositor inflation (#811), and assets in old strategies missing from totals (#797). https://code4rena.com/reports/2023-11-kelp ; https://github.com/code-423n4/2023-11-kelp-findings/issues/584 ; https://github.com/code-423n4/2023-11-kelp-findings/issues/797
- **stETH 1–2 wei transfer shortfall.** Share-based balances floor twice per transfer; use `transferShares` or wstETH. https://docs.lido.fi/guides/lido-tokens-integration-guide/ ; https://github.com/lidofinance/lido-dao/issues/442
- **Lido withdrawal finalization and bunker mode.** Requests finalize in batches under a `maxShareRate`; mass slashing slows finalization so losses are socialized before exits. https://docs.lido.fi/contracts/withdrawal-queue-erc721/ ; https://docs.lido.fi/guides/oracle-spec/accounting-oracle/
- **EigenLayer slashing (ELIP-002, mainnet Apr 2025).** Operator sets, unique stake allocation via magnitudes, slashable queued withdrawals, and the delays quoted above. https://github.com/eigenfoundation/ELIPs/blob/main/ELIPs/ELIP-002.md ; https://github.com/Layr-Labs/eigenlayer-contracts/blob/main/docs/core/AllocationManager.md
- **Rocket Pool RPIP-61 (2024).** Caps the rETH rate change per balance update and enforces a minimum interval between updates. https://rpips.rocketpool.net/RPIPs/RPIP-61
