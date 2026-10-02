# Lending playbook

Load when: the code holds collateral against debt and decides solvency from a price: `borrow`/`repay`/`liquidate`/`healthFactor`/`getAccountLiquidity`, cToken/aToken/debtToken share tokens, `exchangeRate`/`liquidityIndex`/`borrowIndex`, interest-rate models, or a Compound v2 / Aave v2-v3 / Morpho / Euler fork.

## Core invariants

1. After every state-changing call that ends with the caller's account, that account is healthy (`collateralValue * LT >= debtValue`) unless the call was `repay`, `liquidate`, or a deposit of collateral.
2. `sum(user debt shares) * borrowIndex == totalBorrows` within the rounding of one unit per user; each user's rounding favors the protocol (debt rounds up, supply rounds down).
3. `cash + totalBorrows - reserves == totalSupplyShares * exchangeRate` within rounding, and `exchangeRate` never decreases except through realized bad debt.
4. `borrowIndex` and `liquidityIndex` are monotonically non-decreasing and both are accrued before any read of balances, rates, or health in the same call.
5. A position with health factor below 1 is liquidatable in every state where repay is allowed; a pause that blocks liquidation also blocks borrowing and stops interest from pushing users under water.
6. A liquidation never leaves the borrower less healthy than before it, unless it closes the position or records bad debt explicitly.
7. Liquidator receives `repaid * price_debt / price_coll * (1 + bonus)` of collateral, capped at the borrower's collateral; a shortfall is socialized through a recorded deficit, not hidden in `exchangeRate`.
8. Donating underlying to a market (direct transfer) changes no user's borrowing power by more than the donated value.
9. Every collateral token's price is in the same unit and scale as every debt token's price at the time of the health check.

## Where value moves

- **Entry:** `mint`/`supply`/`deposit`, `borrow`, `repay`/`repayBehalf`, `liquidate`/`liquidationCall`, `flashLoan`, `redeem`/`redeemUnderlying`/`withdraw`, collateral enable/disable (`enterMarkets`/`setUserUseReserveAsCollateral`), share transfers of aTokens/cTokens (which move collateral).
- **Exit:** `redeem`, `withdraw`, `borrow`, liquidation seize, `sweepToken`/`rescue`, reserve withdrawal (`_reduceReserves`, treasury mint), flash-loan payout.
- **Privileged parameters:** collateral factor / LTV, liquidation threshold, liquidation bonus, close factor, reserve factor, supply/borrow caps, interest-rate model, oracle address, market listing, pause guardian, eMode/isolation config. Each change takes effect on existing positions: check whether lowering LTV or LT liquidates users instantly (SOL-CR-4) and whether the setter validates `LT >= LTV` and `LT * (1+bonus) < 1` (SOL-CR-7).
- **External dependencies:** price oracle (Chainlink, TWAP, vault exchange rate, LP pricing), the collateral token's transfer hooks, flash-loan providers, keepers/liquidators, governance timelock that lists markets.

Enumerate every pair (collateral asset, debt asset) and for each pair record oracle source, decimals, LTV/LT/bonus, and whether either side is a share token whose price derives from a pool balance. The pairs whose price derives from a balance are the first-priority attack surface.

## Bug classes

### Empty-market share inflation (Compound v2 / Aave forks)
- **Mechanism:** a freshly listed market with near-zero share supply derives `exchangeRate` from `getCash()` (a balance). The attacker mints, redeems down to 1–2 wei of shares, donates underlying so 1 share is worth the whole donation, borrows elsewhere against it, then calls `redeemUnderlying` for slightly less than the donation: the shares-to-burn computation rounds down to 0 or 1 share and the attacker exits with the collateral while the debt stays.
- **Where to look:** `exchangeRateStored`, `redeemFresh`, `redeemUnderlying` (shares = amount / rate, rounded down), Aave `rayDiv` in `AToken.burn`, any market-listing proposal or script that sets a non-zero collateral factor before seeding supply.
- **Ask:** can `totalSupply` of any market reach a value where one share is worth more than the market's borrowable cash, and does any burn path compute shares from an amount with round-down?
- **Prove:** Foundry PoC on a fresh market: mint, redeem to 2 wei, `transfer` underlying to the market, borrow another asset, `redeemUnderlying(cash - 1)`; assert attacker's net balance increased and the market has bad debt. Property: `redeemUnderlying(x)` burns `ceil(x / rate)` shares. Fix shape: burn dead shares at listing, list with collateral factor 0 until seeded, round share burns up.

### Missing health check on a balance-reducing path
- **Mechanism:** a function that reduces collateral or increases debt skips `checkLiquidity`/`validateHealthFactor`. Euler's `donateToReserves` burned the caller's eTokens with no health check, leaving an insolvent position that the attacker self-liquidated at the maximum discount.
- **Where to look:** every function that burns supply shares, transfers collateral shares (`transfer`/`transferFrom` of cToken/aToken), disables collateral, mints debt, or migrates positions; batch/multicall routers that defer checks to the end.
- **Ask:** for each function that lowers `collateralValue - debtValue`, which line enforces the health check, and does a deferred check run on every exit path including the early return?
- **Prove:** fuzz handler that calls each mutator then asserts invariant 1 for the caller; PoC that creates a position, calls the unchecked path, then liquidates it from a second address and shows profit.

### Liquidation math and incentives
- **Mechanism:** bonus applied on the wrong side, seize computed in the wrong decimals, close factor bypassed via repeated calls, liquidation that makes the position worse (bonus > the collateral cushion, so each liquidation lowers HF), bad debt left unrecorded, dust positions with no profitable liquidation.
- **Where to look:** `liquidateCalculateSeizeTokens`, `_calculateAvailableCollateralToLiquidate`, close factor application, rounding in seize (should round in favor of the protocol, not the liquidator), protocol liquidation fee carve-out.
- **Ask:** with LT, bonus, and the price ratio given, does HF after a maximal liquidation exceed HF before it for every HF in (1 - bonus, 1)? What happens below that band?
- **Prove:** property: `hfAfter >= hfBefore || collateralAfter == 0`. Unit test at boundary HFs and at the smallest liquidatable position. Compare against Aave v3.3 behavior (50% close factor above HF 0.95 and above a base-currency size threshold, otherwise 100%; reverts with `MustNotLeaveDust` when leftovers fall below `MIN_LEFTOVER_BASE`).

### Liquidation blocked or front-run
- **Mechanism:** the borrower makes liquidation revert: blocklisted collateral or debt token on transfer to the liquidator, ERC-777/hook token reverting, collateral split across many tiny markets so the liquidator runs out of gas, front-running with a tiny repay so the liquidator's exact-amount repay reverts, a pause that blocks liquidation while interest still accrues.
- **Where to look:** seize transfers (push to liquidator vs internal balance credit), `repayAmount > borrowBalance` handling (revert vs clamp), loops over the user's markets, pause flags per action.
- **Ask:** can the borrower, by any action of their own, cause a pending `liquidate` to revert?
- **Prove:** PoC: borrower front-runs with `repay(1)`; liquidator's call reverts. Property: if `hf < 1` then `liquidate(user, debt, coll, closeFactorMax)` succeeds for an honest liquidator with funds.

### Oracle mismatch and manipulable collateral price
- **Mechanism:** collateral priced from AMM spot, a short TWAP on a thin pool, an LP token valued as `reserves * price`, a vault share valued by `convertToAssets` on a near-empty vault, or a Chainlink feed returning `minAnswer` during a crash; the attacker inflates collateral or deflates debt and borrows out the market.
- **Where to look:** every `getPrice`/`getUnderlyingPrice` branch; ERC-4626 collateral adapters (pair with [vaults](skill://smart-contract-audit/references/playbooks/vaults.md)); LP oracles; `price` inverted as `1e36 / price` (rounds to 0 for large prices).
- **Ask:** how much capital moves this asset's reported price by 10% within one transaction or one TWAP window, and does that cost exceed the borrowable cash?
- **Prove:** PoC with a flash loan that skews the source, deposits, borrows, and unwinds. For Chainlink: fork test with a mocked aggregator answering at `minAnswer` while the real market is below it.

### Interest accrual ordering
- **Mechanism:** `accrueInterest` skipped on one path, so a user borrows or repays at a stale index; the rate model reads utilization after the action instead of before; reserve factor change applied retroactively; index update divides by a supply that can be zero.
- **Where to look:** every external function: does the first line accrue for every market it touches (both collateral and debt markets in a liquidation)? Rate-model `getBorrowRate(cash, borrows, reserves)` call sites.
- **Ask:** is any balance, rate, or health read before the market's accrual in the same call?
- **Prove:** differential test: same sequence with and without an explicit `accrueInterest()` before each step must produce identical balances.

### Reentrancy through token hooks across markets
- **Mechanism:** `borrow` transfers out before recording debt; a token with a transfer hook (ERC-777, ERC-677 `onTokenTransfer`, native ETH send) reenters a different market whose own lock is separate and borrows again against collateral not yet encumbered. Cream (AMP) and Hundred/Agave (ERC-677 bridged tokens) lost funds this way.
- **Where to look:** `doTransferOut` placement relative to `accountBorrows` writes; per-market `nonReentrant` vs a global lock in the comptroller; native ETH markets.
- **Ask:** does any market send tokens or ETH before the protocol-wide debt state is final, and is the reentrancy lock shared across markets?
- **Prove:** PoC with a mock hook token that reenters `borrow` on a second market during the first `borrow`'s transfer.

### Self-liquidation and same-block position games
- **Mechanism:** a user liquidates themselves to capture the bonus from their own collateral when bonus > interest or fees; a user lends and borrows the same asset to farm rewards or inflate utilization; a user borrows and repays in one transaction to manipulate an index used by an integrator (flash-loan index inflation in Aave-style markets).
- **Where to look:** `liquidate` with `borrower == msg.sender` or a contract the borrower controls; reward distribution keyed on supply or borrow balances; flash-loan premium routed into `liquidityIndex`.
- **Ask:** is any profitable action available to an account that is both sides of a liquidation, both lender and borrower, or both flash borrower and depositor?
- **Prove:** PoC with two attacker-controlled addresses showing net profit after costs.

### Rounding direction in share and debt conversion
- **Mechanism:** debt shares minted with round-down (borrower owes less than borrowed), supply shares burned with round-down (redeemer receives more than burned), repay converting amount to shares with round-down so 1 wei of debt can never be repaid, `elastic`/`base` rebasing where `elastic` reaches 0 while `base > 0`.
- **Where to look:** `toShares`/`toAmount` helpers, `mulDiv` call sites, `rayMul`/`rayDiv` (round half up), any `base`/`elastic` struct.
- **Ask:** for each conversion, who benefits from the rounding, and can a loop of 1-wei operations extract value or brick a position?
- **Prove:** fuzz property: `borrow(x)` then `repay(debtOf(user))` returns the market to its prior `totalBorrows` or higher; `deposit(x)` then `withdraw(max)` never returns more than `x`.

### Isolated, siloed, and cross-margin configuration
- **Mechanism:** isolation-mode debt ceilings counted in the wrong decimals, siloed borrowing bypassed through a second collateral, eMode price override applied to assets outside the category, a collateral factor change on an existing market that instantly liquidates users.
- **Where to look:** `validateBorrow`, eMode category checks, debt ceiling accounting on repay/liquidate (decremented with the same rounding as increment?).
- **Ask:** for each restriction, which state transition (repay, liquidate, collateral toggle, eMode switch) fails to update it?
- **Prove:** stateful fuzz over the restriction transitions with the restriction as an invariant.

### Bad debt recognition
- **Mechanism:** a position with zero collateral and non-zero debt stays on the books, keeps accruing interest, and inflates `totalBorrows`, so `exchangeRate` overstates what suppliers can withdraw; the last suppliers to exit absorb the loss (bank run). Explicit-deficit designs fail differently: the deficit is never realized because dust collateral remains, or it is charged to the wrong reserve.
- **Where to look:** post-liquidation cleanup (Aave v3.3 burns remaining debt and records a reserve deficit when collateral reaches 0), interest accrual on zero-collateral accounts, reserve/insurance coverage functions, `exchangeRate` formula.
- **Ask:** after a price crash that makes a position underwater, which account's balance reflects the loss, and when?
- **Prove:** PoC: crash the collateral price below debt, liquidate fully, then let every supplier withdraw in turn; assert the shortfall falls on the last withdrawers instead of pro rata.

### Pool flash loans and same-transaction state
- **Mechanism:** the market's own `flashLoan` lends out cash while internal accounting still counts it; during the callback, `getCash()`-based rates, `exchangeRate`, or utilization read wrong values, and reentry into `mint`/`borrow`/`liquidate` acts on them. The premium credited to `liquidityIndex` on a tiny supply inflates the index (Radiant).
- **Where to look:** `flashLoan` reentrancy guard scope (shared with `mint`/`borrow`?), premium accounting, `getCash` reads during callbacks.
- **Ask:** which protocol functions are callable from inside a flash-loan callback, and what do they read for cash and index?
- **Prove:** PoC: inside `executeOperation`, call `mint` or `redeem` and compare the exchange rate used to the rate after repayment.

## Checklist items to walk

- Lending: SOL-Defi-Lending-1, SOL-Defi-Lending-2, SOL-Defi-Lending-3, SOL-Defi-Lending-4, SOL-Defi-Lending-5, SOL-Defi-Lending-6, SOL-Defi-Lending-7, SOL-Defi-Lending-8, SOL-Defi-Lending-9, SOL-Defi-Lending-10, SOL-Defi-Lending-11, SOL-Defi-Lending-12
- Oracles: SOL-Defi-Oracle-1, SOL-Defi-Oracle-2, SOL-Defi-Oracle-3, SOL-Defi-Oracle-4, SOL-Defi-Oracle-6, SOL-Defi-Oracle-7, SOL-Defi-Oracle-8, SOL-Defi-Oracle-11, SOL-Defi-Oracle-12, SOL-Defi-Oracle-13, SOL-Defi-Oracle-14, SOL-AM-PMA-1, SOL-AM-PMA-2
- Shares and donations: SOL-Defi-General-3, SOL-Defi-General-4, SOL-Defi-General-7, SOL-AM-DA-1, SOL-Defi-FlashLoan-1, SOL-Defi-FlashLoan-2
- Integrating Aave/Compound: SOL-Integrations-AC-1, SOL-Integrations-AC-2, SOL-Integrations-AC-3, SOL-Integrations-AC-4, SOL-Integrations-AC-5, SOL-Integrations-AC-6, SOL-Integrations-AC-7, SOL-Integrations-AC-8, SOL-Integrations-AC-9
- Math: SOL-Basics-Math-4, SOL-Basics-Math-5, SOL-Basics-Math-6, SOL-Heuristics-7, SOL-Heuristics-10
- Reentrancy and calls: SOL-EC-1, SOL-EC-13, SOL-AM-ReentrancyAttack-1, SOL-AM-ReentrancyAttack-2, SOL-Token-FE-7
- Denial of liquidation: SOL-AM-DOSA-3, SOL-AM-DOSA-6, SOL-Token-FE-4, SOL-Token-FE-15, SOL-AM-FrA-3
- Admin: SOL-CR-2, SOL-CR-4, SOL-CR-7, SOL-Timelock-1
- Heuristics: SOL-Heuristics-3, SOL-Heuristics-9, SOL-Heuristics-13, SOL-Heuristics-16, SOL-Heuristics-17
- Token behavior: weird-ERC20 catalog ids A1, B1, B2, B4, D4, D5, E1, E3, F1, G4, G5 in [weird-erc20](skill://smart-contract-audit/references/weird-erc20.md). Map each listed collateral and debt token to the catalog before evaluating seize and repay paths.
- Whole categories: [upgradeability](skill://smart-contract-audit/references/upgradeability.md), [arbitrary calls and approvals](skill://smart-contract-audit/references/arbitrary-calls-approvals.md) (position managers, migrators, flash-loan receivers), [chain-specific](skill://smart-contract-audit/references/chain-specific.md) (L2 sequencer, block time assumptions in rate models).

Proof tooling: [exploit PoC](skill://test-foundry/references/exploit-poc.md), [property catalog](skill://fuzz-echidna-medusa/references/property-catalog.md). Rate findings with [severity](skill://smart-contract-audit/references/methodology/severity.md).

## Precedent

- **Euler Finance, Mar 2023.** `donateToReserves` (added by eIP-14) burned eTokens without a health check; the attacker made itself insolvent and self-liquidated at up to a 20% discount. https://www.certik.com/blog/euler-finance-incident-analysis ; https://medium.com/@omniscia.io/euler-finance-incident-post-mortem-1ce077c28454
- **Hundred Finance, Apr 2023 (Optimism).** Empty hWBTC market in a Compound v2 fork: redeem to ~2 wei of shares, donate WBTC to inflate `exchangeRate`, borrow, exploit round-down in `redeemUnderlying`. https://blocksec.com/blog/6-hundred-finance-incident-catalyzing-the-wave-of-precision-related-exploits-in-vulnerable-forked-protocols ; https://www.comp.xyz/t/hundred-finance-exploit-and-compound-v2/4266
- **Onyx Protocol, Nov 2023.** Same empty-market rounding class on a governance-listed PEPE market with no initial liquidity. https://www.certik.com/blog/post-mortem-onyx-protocol
- **Sonne Finance, May 2024 (Optimism).** Timelocked proposals to list VELO and set its collateral factor were executable by anyone; the attacker executed them, then ran the empty-market donation and `redeemUnderlying` rounding attack. https://medium.com/@SonneFinance/post-mortem-sonne-finance-exploit-12f3daa82b06
- **Radiant Capital, Jan 2024 (Arbitrum, Aave v3 fork).** Newly listed empty USDC market: repeated flash loans inflated `liquidityIndex`, then `rayDiv` rounding in the aToken burn let the attacker withdraw more than deposited. https://medium.com/@RadiantCapital/post-mortem-report-radiant-capital-aea46cb985ae
- **Wise Lending, Jan 2024.** Pool driven to tiny share supply, then share price inflated through deposit/withdraw rounding. https://osec.io/blog/rounding-bugs/
- **Cream Finance, Aug 2021.** AMP's ERC-1820 `tokensReceived` hook reentered during `borrow` before crAMP debt was written; the attacker borrowed from crETH, whose lock was separate. https://medium.com/cream-finance/c-r-e-a-m-finance-post-mortem-amp-exploit-6ceb20a630c5
- **Hundred Finance and Agave, Mar 2022 (Gnosis chain).** ERC-677 transfer callback on bridged tokens reentered borrow before debt was recorded. https://immunefi.com/blog/bug-fix-reviews/hack-analysis-the-hundred-finance-heist-march-2022/
- **Inverse Finance, Apr 2022.** INV collateral priced from a Keep3r TWAP over a thin Sushiswap pool whose window could close after ~15 seconds; the attacker skewed the pool and borrowed against inflated INV. https://www.certik.com/blog/inverse-finance-02-april-2022
- **Venus, May 2022 (BSC).** Chainlink LUNA/USD aggregator held at its `minAnswer` while spot fell far below; attackers deposited LUNA and borrowed at the floor price. https://community.venus.io/t/venus-protocol-luna-incident-update-2/2654 ; mechanism: https://medium.com/arbitrary-execution/circuit-breakers-a-chainlink-deep-dive-52b6f5b8c1e
- **ResupplyFi, Jun 2025.** ERC-4626 collateral with 1 wei of supply was inflated by donation; the oracle's `1e36 / price` floored to 0, LTV computed as 0, and the attacker borrowed the full limit. https://blocksec.com/blog/in-depth-analysis-and-reflections-on-the-resupply-protocol-attack-incident
- **Aave v3.3 contest submission (Sherlock, Jan 2025).** Argues that griefers supplying dust collateral keep the v3.3 bad-debt deficit cleanup from triggering; a worked example of the bad-debt recognition class (check its judging status before citing it as a confirmed bug). https://github.com/sherlock-audit/2025-01-aave-v3-3-judging/issues/156 ; v3.3 design: https://github.com/aave-dao/aave-v3-origin/blob/main/docs/3.3/Aave-v3.3-features.md
