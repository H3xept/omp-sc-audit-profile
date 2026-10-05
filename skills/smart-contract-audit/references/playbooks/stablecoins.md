# Stablecoins and CDP playbook

Load when: the code mints a stable or synthetic asset against collateral or reserves: troves/vaults/CDPs (`openTrove`, `frob`, `borrow` minting a debt token), redemptions (`redeemCollateral`), stability pools, peg stability modules (`sellGem`/`buyGem`, mint/redeem against USDC), algorithmic mint/burn against a volatile token, or a `totalBorrow { elastic, base }` rebase struct.

## Core invariants

1. `stablecoin.totalSupply() == sum(position debt) + PSM/reserve-backed mints + protocol-owned mints - burned bad debt`, at every block; no path mints without a matching debt or reserve entry.
2. Every open position satisfies `collateral * price / debt >= MCR` after any user-initiated action other than repay, deposit of collateral, or close.
3. Redeeming `X` stablecoin returns at most `X` worth of collateral at the oracle price, net of the redemption fee, and burns exactly `X`.
4. Redemption order matches the documented ordering (lowest collateral ratio first in Liquity v1; lowest interest rate first in Liquity v2), and the ordering structure stays sorted after every operation.
5. Stability Pool: each depositor's compounded deposit and collateral gain equal the result of applying every liquidation to their deposit pro rata; the sum of claims never exceeds the pool's holdings.
6. In a `{elastic, base}` rebase, `elastic == 0` if and only if `base == 0`, and `toBase(toElastic(x)) <= x`.
7. PSM: `gem` in plus fee equals stablecoin out, and stablecoin in equals `gem` out plus fee, with decimals converted exactly; PSM mints never exceed its debt ceiling.
8. Interest accrued on debt is minted (or recorded) exactly once, to the recipient defined by the protocol, and increases each position's debt by the same factor.
9. A liquidation either fully covers the position's debt (via Stability Pool, auction, or redistribution) or records the shortfall as bad debt; no shortfall disappears from the books.

## Where value moves

- **Entry:** open/adjust position (`openTrove`, `adjustTrove`, `borrow`, `frob`), deposit collateral, PSM `sellGem`, Stability Pool deposit, auction bids, flash mint of the stablecoin.
- **Exit:** repay/close, collateral withdrawal, redemption, liquidation (SP offset, redistribution, auctions: `bark`/`take`), PSM `buyGem`, Stability Pool withdrawal and gain claims, fee distribution to stakers, surplus/debt auctions.
- **Privileged parameters:** MCR / liquidation ratio, CCR / recovery thresholds, debt ceilings per collateral type, stability fee or interest-rate bounds, redemption fee floor and decay, PSM `tin`/`tout`, auction parameters (duration, price curve, tip/chip incentives), oracle security delays, collateral onboarding, shutdown triggers.
- **External dependencies:** price feeds (Chainlink plus fallback, Maker OSM delay), collateral tokens (LSTs, LP tokens, vault shares), keepers for liquidations and auctions, DEX liquidity for the stablecoin (peg arbitrage is the stabilizer), the PSM reserve asset's issuer (blocklists, depeg).

For each collateral type, record oracle path, MCR, liquidation route, and redemption exposure. For each mint path, record the matching debt or reserve entry that invariant 1 depends on.

## Bug classes

### Unbacked mint path
- **Mechanism:** a function mints the stablecoin without recording debt: flash-mint whose repayment check reads the wrong balance, a zap or migration contract trusted by the debt token, a fee mint double-counted, interest minted to a recipient but not added to debt, or a mint authorized for a contract that can be called with attacker-chosen data.
- **Where to look:** every holder of the debt token's minter role; `flashLoan` / `onFlashLoan` handlers that trust `initiator` or `data`; delegate-approval mechanisms for zaps (Prisma's `MigrateTroveZap` trusted unvalidated `onFlashLoan` data).
- **Ask:** for each minter, which state change records the matching debt, and can an attacker reach the mint with data the protocol did not create?
- **Prove:** invariant 1 as a stateful fuzz property; PoC calling the minter contract directly with crafted calldata.

### Rebase struct rounding (`elastic`/`base`)
- **Mechanism:** a function reduces `elastic` (total debt) without reducing `base` (total shares), such as a public `repayForAll`; the attacker pushes `elastic` toward 0 while `base` stays large, then `toBase` rounding gives the attacker shares worth far more than borrowed, or borrows mint 0 shares.
- **Where to look:** every write to `totalBorrow.elastic` and `totalBorrow.base`; `RebaseLibrary.toBase/toElastic` rounding flags; repay-for-all, donation, or liquidation paths that touch one side.
- **Ask:** can any reachable state have `elastic == 0 && base > 0`, or a ratio `elastic / base` far below 1?
- **Prove:** fuzz invariant 6; PoC repaying many 1-wei amounts to drive the ratio, then borrowing; assert the borrower's debt shares are worth less than borrowed.

### Index and share inflation on a small position base
- **Mechanism:** a stored index or share price derives from a donation-sensitive balance; with a tiny supply, a donation plus liquidation inflates the index, and `divUp` or round-up mints a full share per wei of collateral. Raft minted unbacked R this way.
- **Where to look:** `storedIndex`, collateral share tokens, `divUp` / `mulDivUp` in mint paths, liquidation redistribution that updates per-unit indices.
- **Ask:** what happens to the index when total collateral shares are 1 wei and someone donates?
- **Prove:** PoC: create a minimal position, donate collateral to the manager, trigger liquidation of a prepared position, then mint; assert minted stablecoin exceeds collateral value.

### Redemption mechanics
- **Mechanism:** the ordering structure goes stale (insert with wrong hints, ICR-based order broken by redistribution or interest, ties ordered inconsistently); redemption skips or hits the wrong positions; partial redemption leaves dust below minimum debt; the fee is computed before `baseRate` decay or after the burn; redemptions are cheap enough to target one position repeatedly as griefing.
- **Where to look:** sorted list insert/reinsert (`SortedTroves`), hint helpers, `redeemCollateral` loop bounds (`maxIterations`), partial-redemption NICR check, `baseRate` update and decay, `MIN_NET_DEBT`. Liquity v1 orders by NICR, which redistribution preserves; Liquity v2 orders by user-set interest rate and shields a branch while its Stability Pool covers its debt.
- **Ask:** for each operation that changes a position's sort key, is the position reinserted, and does the redemption loop stop at the documented condition?
- **Prove:** stateful fuzz with invariant 4 checked by walking the list; unit test on partial redemption with a stale hint (must cancel the partial, not revert the whole redemption or leave dust).

### Stability Pool accounting
- **Mechanism:** the running product `P` and per-scale sums lose precision after near-total depletions; `P` reaching 0 or below the scale factor corrupts every deposit's compounded value or reverts liquidations; depositors withdraw just before a liquidation lands (front-run) or deposit just before to harvest the collateral gain; rounding error feedback is dropped.
- **Where to look:** `_updateRewardSumAndProduct`, scale-change branch, `getCompoundedDeposit`, `getDepositorETHGain`, minimum pool size (`MIN_LUSD_IN_SP` in Liquity), withdrawal blocks while liquidatable positions exist.
- **Ask:** after a liquidation that empties all but a tiny fraction of the pool, are `P` and the scale updated so later deposits still compound correctly?
- **Prove:** fuzz liquidation fractions near 1 and assert invariant 5 across many depositors; differential test against a naive per-depositor loop on a small set.

### Liquidation and auction design
- **Mechanism:** auctions under congestion clear at zero or near-zero bids; liquidation incentives exceed the collateral cushion so liquidation worsens solvency; recovery mode triggers liquidations of healthy positions that an attacker can force by moving TCR; redistribution to other positions pushes them under MCR in cascade.
- **Where to look:** auction price curve and minimum bid, `chip`/`tip` keeper incentives, recovery mode transitions, redistribution of debt and collateral, `liquidateTroves` batch bounds.
- **Ask:** what does the protocol recover if the only bidder bids the minimum, and can a user push the system into a mode that liquidates someone else at a discount?
- **Prove:** simulation of an auction with one low bidder; PoC that drops TCR via a large borrow and then liquidates a victim under recovery rules.

### Peg stability module
- **Mechanism:** decimal conversion off between the gem (often 6 decimals) and the 18-decimal stablecoin; fees rounded toward the user; PSM capacity exhausted and arbitrage stops; reserve asset blocklists the PSM or depegs, so the stablecoin inherits the depeg at the PSM's fixed rate.
- **Where to look:** `sellGem`/`buyGem` conversion (`to18ConversionFactor`), `tin`/`tout` application, debt ceiling, any donation path that changes reserves.
- **Ask:** for `x` gem units, is the stablecoin minted exactly `x * 10**(18 - gemDecimals) * (1 - tin)` rounded down?
- **Prove:** fuzz invariant 7 with 6- and 18-decimal gems; scenario test with the gem paused or blocklisting the PSM.

### Oracle path for collateral
- **Mechanism:** collateral priced from a manipulable source (vault share `convertToAssets`, LP spot, DEX spot), a Chainlink feed at its floor, or an inverted price that floors to 0; the attacker opens an under-collateralized position and keeps the minted stablecoin.
- **Where to look:** price adapters per collateral, fallback switching logic between primary and secondary feeds, frozen-oracle handling, security delays such as Maker's OSM.
- **Ask:** which collateral has the cheapest price manipulation relative to its debt ceiling?
- **Prove:** PoC with a flash loan moving the source, open a position at max LTV, unwind. Cross-reference the oracle class in the [lending playbook](skill://smart-contract-audit/references/playbooks/lending.md) and the share-pricing class in the [vaults playbook](skill://smart-contract-audit/references/playbooks/vaults.md).

### Reflexive and algorithmic designs
- **Mechanism:** the stablecoin redeems for a governance or volatile token minted on demand; when the volatile token's market cap falls below the stablecoin's supply, redemptions hyperinflate it and the peg breaks; governance power held in the same token lets a flash-loaned majority pass a draining proposal.
- **Where to look:** mint/burn arbitrage loops, redemption caps, governance voting power source and snapshot timing, emergency execution paths.
- **Ask:** what backs one stablecoin when the backing token loses 90% of its market value, and can governance be acquired within one transaction?
- **Prove:** economic simulation script over price paths; for governance, see the [governance playbook](skill://smart-contract-audit/references/playbooks/governance.md).

### Interest and fee accrual
- **Mechanism:** interest accrued per position on read but minted globally on a different schedule, so supply and debt drift; user-set rates (Liquity v2) changed without accruing at the old rate; fee rebates or redemption fee decay computed with time-unit errors.
- **Where to look:** `accrueInterest`, `_mintAggInterest`, rate adjustment functions, `baseRate` decay (`minutes` vs `seconds`).
- **Ask:** does `sum(position debt)` equal the global debt aggregate after each operation?
- **Prove:** stateful fuzz on invariant 8 with time warps between operations.

### Shutdown, global settlement, and branch sunset
- **Mechanism:** emergency shutdown freezes prices and lets stablecoin holders claim collateral; ordering between position holders withdrawing excess collateral and stablecoin holders redeeming decides who absorbs the shortfall; a frozen price taken during a manipulation is permanent. Liquity v2 shuts down a branch on collateral or oracle failure and then allows 0%-fee redemptions with a collateral bonus where the redeemer picks troves, so a shutdown trigger an attacker can reach is a direct extraction path.
- **Where to look:** `cage`/`shutdown`/`shutDown`, triggers (permissionless oracle-failure checks, TCR thresholds), claim functions for holders and position owners after settlement.
- **Ask:** who can trigger shutdown, from which state, and does the settlement price come from a source that could be manipulated in the triggering transaction?
- **Prove:** PoC: manipulate or brick the oracle to satisfy the trigger, shut down, then redeem at the post-shutdown terms; assert profit relative to normal redemption.

### Collateral onboarding and debt ceilings
- **Mechanism:** a new collateral type is listed with a working oracle but zero liquidity for liquidations, or before its Stability Pool or auction path exists; debt ceilings are incremented on borrow but decremented with different rounding (or not at all) on repay and liquidation, so the ceiling drifts and blocks borrowing or lets borrowing exceed it.
- **Where to look:** collateral registration, per-collateral `debtCeiling`/`line` accounting in borrow, repay, liquidation, and redistribution.
- **Ask:** after a full borrow, repay, and liquidate cycle on one collateral type, does its tracked debt return to zero?
- **Prove:** stateful fuzz with the invariant `trackedDebt[collateral] == sum(position debt for collateral)`.

## Checklist items to walk

- Peg and pricing: SOL-Defi-General-5, SOL-AM-PMA-1, SOL-AM-PMA-2, SOL-Defi-Oracle-2, SOL-Defi-Oracle-3, SOL-Defi-Oracle-4, SOL-Defi-Oracle-7, SOL-Defi-Oracle-8, SOL-Defi-Oracle-10, SOL-Defi-Oracle-11, SOL-Defi-Oracle-12, SOL-Defi-Oracle-13, SOL-Defi-Oracle-14
- Liquidation (same mechanics as lending): SOL-Defi-Lending-1, SOL-Defi-Lending-2, SOL-Defi-Lending-3, SOL-Defi-Lending-4, SOL-Defi-Lending-6, SOL-Defi-Lending-7, SOL-Defi-Lending-11, SOL-Defi-Lending-12
- Flash mint and flash loans: SOL-Token-FE-9, SOL-Defi-FlashLoan-1, SOL-Integrations-Balancer-1
- Shares and donations: SOL-Defi-General-3, SOL-Defi-General-4, SOL-Defi-General-7, SOL-AM-DA-1
- Math: SOL-Basics-Math-4, SOL-Basics-Math-5, SOL-Basics-Math-6, SOL-Basics-Math-12, SOL-Heuristics-7, SOL-Heuristics-10, SOL-Heuristics-17
- Loops and ordering: SOL-Basics-AL-4, SOL-Basics-AL-9, SOL-Basics-AL-10, SOL-AM-DOSA-4, SOL-AM-MA-3
- Front-running: SOL-AM-FrA-2, SOL-AM-FrA-3, SOL-AM-SandwichAttack-1, SOL-AM-GA-1
- External calls and callbacks: SOL-EC-1, SOL-EC-13, SOL-AM-ReentrancyAttack-1, SOL-Defi-AS-12
- Liveness: SOL-AM-DOSA-1, SOL-AM-DOSA-3, SOL-AM-DOSA-6
- Admin: SOL-CR-2, SOL-CR-4, SOL-CR-7, SOL-Timelock-1
- Token behavior: weird-ERC20 catalog ids A1, B1, B3, B4, D4, D5, F4, F5, G4 in [weird-erc20](skill://smart-contract-audit/references/weird-erc20.md), applied to both collateral and the PSM reserve asset.
- Whole categories: [upgradeability](skill://smart-contract-audit/references/upgradeability.md), [arbitrary calls and approvals](skill://smart-contract-audit/references/arbitrary-calls-approvals.md) (zaps with delegate approval, flash-loan receivers), [chain-specific](skill://smart-contract-audit/references/chain-specific.md) (L2 sequencer for oracle freshness).

Proof tooling: [exploit PoC](skill://test-foundry/references/exploit-poc.md), [property catalog](skill://fuzz-echidna-medusa/references/property-catalog.md). Rate findings with [severity](skill://smart-contract-audit/references/methodology/severity.md).

## Precedent

- **MakerDAO Black Thursday, Mar 2020.** Network congestion and a price crash left keepers unable to bid; many collateral auctions cleared at 0 DAI, leaving the system undercollateralized and requiring an MKR debt auction. https://medium.com/@whiterabbit_hq/black-thursday-for-makerdao-8-32-million-was-liquidated-for-0-dai-36b83cac56b6 ; https://www.coindesk.com/tech/2020/07/22/mempool-manipulation-enabled-theft-of-8m-in-makerdao-collateral-on-black-thursday-report
- **Abracadabra CauldronV4, Jan 2024.** `repayForAll` reduced `totalBorrow.elastic` without `base`; the attacker drove elastic toward zero and exploited rounding in the share conversion to borrow the cauldron's funds. https://github.com/matt-osec/mimhack ; https://docs.phylax.systems/assertions-book/previous-hacks/abracadabra-rounding-error
- **Raft, Nov 2023.** A cbETH donation plus liquidation of a prepared position inflated `storedIndex`, and round-up share minting let the attacker mint unbacked R. https://paragraph.com/@raft/raft-security-incident-post-mortem-analysis-and-recovery-plan
- **Prisma Finance, Mar 2024.** `MigrateTroveZap.onFlashLoan` acted on unvalidated data from a directly invoked debt-token flash loan; users had delegate-approved the zap, so the attacker closed and reopened their troves with less collateral. https://hackmd.io/@PrismaRisk/PostMortem0328
- **ResupplyFi, Jun 2025.** ERC-4626 collateral inflated by donation; the oracle's `1e36 / price` floored to 0 and the attacker minted reUSD against near-zero collateral. https://paragraph.com/@resupply/resupply-crvusd-wstusr-market-post-mortem
- **Beanstalk, Apr 2022.** Flash-loaned governance power passed and executed (via `emergencyCommit`) a proposal that drained the protocol. https://immunefi.com/blog/bug-fix-reviews/hack-analysis-beanstalk-governance-attack-april-2022/
- **Terra UST/LUNA, May 2022.** Mint/burn reflexivity: once LUNA's value fell below UST supply, redemptions hyperinflated LUNA and the peg collapsed. https://www.richmondfed.org/publications/research/economic_brief/2022/eb_22-24
- **Liquity Stability Pool product underflow advisory.** Liquidations that consume nearly all of the pool could drive the running product `P` toward 0 and revert; fixed by adjusting the scale-change logic. https://github.com/liquity/dev/security/advisories/GHSA-m9f3-hrx8-x2g3
- **Liquity v2 redeployment, 2025.** The protocol redeployed after an issue found in its Stability Pool. https://www.liquity.org/blog/liquity-v2-redeployment
- **Design references.** Liquity v1 ordering, hints, recovery mode, and redemption fee: https://github.com/liquity/dev/blob/main/README.md ; Liquity v2 interest-rate-ordered redemptions: https://docs.liquity.org/v2-faq/redemptions-and-delegation ; Liquity v2 branch shutdown (TCR below SCR or oracle failure) and urgent redemptions: https://docs.liquity.org/v2-documentation/risk-disclosure ; Maker PSM: https://github.com/makerdao/dss-psm
