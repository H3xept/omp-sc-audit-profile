# Perpetuals playbook

Load when: the code opens leveraged positions against an oracle price and settles PnL in collateral: GMX v1 (`Vault.increasePosition`/`decreasePosition`, `reservedAmounts`, `PositionRouter`, GLP), GMX v2 (`OrderHandler.executeOrder`, GM pools, `maxPnlFactor`, ADL), Synthetix perps (delayed and off-chain delayed orders, `skewScale`, funding velocity, v3 multi-collateral accounts), dYdX-, Vertex-, or Hyperliquid-style engines (maintenance weights, insurance fund, backstop vault); or any code with `fundingRate`/`cumulativeFunding`, a mark/index price split, keeper-executed order requests, open-interest caps, or trader PnL paid from an LP pool.

## Core invariants

1. Every position mutation (increase, decrease, collateral add or remove, liquidation, ADL) first updates the global funding and borrow accumulators, then settles the position's accrued fees, then changes size or collateral.
2. Per interval and per collateral token, funding paid by the paying side equals funding credited to the receiving side plus the protocol cut; nothing accrues to a side with zero open interest.
3. Global open interest per market and side equals the sum of open position sizes on that side; every cap check uses the post-trade value.
4. Pool assets minus reserved amounts cover the maximum payout of every open position; LP redemptions cannot take the pool below reserved amounts.
5. Pool value for LP mint and redeem equals pool assets minus net trader PnL minus fees owed to traders, and each side uses the price that favors the pool (max on mint, min on redeem).
6. A keeper-executed order fills at a price with a timestamp after the order's creation and within a bounded age; neither the trader nor the keeper chooses among valid prices.
7. Opening and closing a position at an unchanged price returns at most collateral minus a strictly positive open fee and close fee.
8. The margin check is identical on decrease, collateral withdrawal, and liquidation: same price side, same fees, same collateral haircuts.
9. A position below maintenance margin is liquidatable in every state, and a liquidation pays out at most the position's collateral plus the documented backstop (insurance fund, then ADL or socialized loss).
10. Every price used in PnL, margin, or division is strictly positive (or the market documents signed prices), lies inside its bounds, and has `minPrice <= maxPrice`.
11. Isolated collateral backs only its own position; cross-margin equity counts unrealized profit only within a documented limit for withdrawals and new risk.

## Where value moves

- **Entry:** `createIncreasePosition`/`createOrder`/`commitOrder`/`submitOffchainDelayedOrder`, collateral deposit, `cancelOrder` (refunds), LP `mintAndStakeGlp`/`createDeposit`, execution-fee payments in native ETH.
- **Exit:** `decreasePosition` payouts, `withdrawCollateral`/`withdrawMargin`, funding claims (`claimFundingFees`), liquidation fee to the keeper, execution-fee refunds to a user-chosen receiver, LP `unstakeAndRedeemGlp`/`createWithdrawal`, insurance-fund debits.
- **Keeper and privileged execution:** `executeIncreasePosition`, `executeOrder`, `liquidatePosition`/`flagPosition`, `executeAdl`, funding updates, price submission (`setPricesWithBits`, signed or Pyth payloads), market settlement or delisting.
- **Privileged parameters:** keeper and price-signer sets, max leverage, initial and maintenance margin, liquidation fee, min collateral and min position size, funding and borrow factors, `skewScale`, price-impact factors, OI caps, reserve factors, max PnL factors, ADL thresholds, collateral haircuts, oracle max age and spread. Check whether each change applies to open positions at once (SOL-CR-4) and whether setters bound it (SOL-CR-7).
- **External dependencies:** Chainlink feeds and sequencer uptime, pull oracles (Pyth `price`, `conf`, `expo`, `publishTime`), the spot venues the oracle tracks, collateral tokens, WETH unwrap, user callback contracts.

For each market, record the execution price source, the liquidation price source, the collateral tokens with their haircuts, and the OI cap relative to the reference venue's depth. A market with a high OI cap on a thin reference venue is the first-priority attack surface.

## Bug classes

### Index and mark price manipulation for execution and liquidation
- **Mechanism:** oracle-priced execution fills at the reference price with zero or capped price impact. The attacker opens a large position, moves the thin venues that feed the index, and closes against the LP pool at the moved price. A mark price taken from the protocol's own vAMM or order book lets the attacker push mark to liquidate others or to inflate unrealized profit. GMX v1 on Avalanche (Sep 2022) lost GLP value this way on AVAX.
- **Where to look:** where execution and liquidation each read price; `getMaxPrice`/`getMinPrice` spread use; per-market `maxGlobalLongSize`/`maxOpenInterest`; any internal pool or TWAP used as mark; who submits the price payload and how the caller is authorized (`_msgSender()` behind ERC-2771 forwarders).
- **Ask:** what does it cost to move the reference venue by the fee plus spread, and what is the maximum profit at the OI cap for that move?
- **Prove:** fork test: open at the cap, move the mocked index by `x`, close; assert profit < cost of moving the venue by `x`. For mark/index splits: push mark only, assert no healthy position becomes liquidatable.

### Keeper execution ordering and stale-price execution
- **Mechanism:** the trader creates a request; a keeper executes it later. If the keeper may use any signed price inside the age window, the keeper or a colluding trader picks the best one. If the trader sees the next price before it lands (Chainlink deviation lag, Pyth published off-chain), they create or cancel a request to trade against it. A `minExecutionFee` below real gas cost leaves requests unexecuted until a favorable price; a callback or receiver that reverts lets the trader veto unfavorable fills.
- **Where to look:** `minBlockDelayKeeper`, `maxTimeDelay`, `offchainDelayedOrderMinAge`/`MaxAge`, comparison of price `publishTime` against request creation time, `cancelOrder` timing, `GasUtils.validateExecutionFee`, refund via `sendValue`, behavior when execution reverts (cancel vs retry).
- **Ask:** after the execution price is knowable, can the trader or the keeper still decide whether, or at which price, the order fills?
- **Prove:** test with a trader callback that reverts on unfavorable prices; assert the order cancels with the fee kept. Test execution with a price whose timestamp is one second before creation; assert revert.

### Funding-rate accounting asymmetry
- **Mechanism:** funding flows from the heavier side to the lighter side. Bugs: the payer side is charged `rate * longOI` but receivers are credited with the payer's per-size index; funding accrues while one side's OI is zero, so it is credited to nobody or minted from the pool; the rate uses skew after the caller's own trade; `increasePosition` resets `entryFundingRate` or `fundingFeeAmountPerSize` without settling the accrued amount; per-block updates round the increment `rate * elapsed / PRECISION` to zero.
- **Where to look:** `updateCumulativeFundingRate`, `_updateFunding`, `getNextFundingAmountPerSize`, every write to a position's funding snapshot, funding paid in long token vs short token collateral, `claimableFundingAmount`.
- **Ask:** across one interval, does total funding debited equal total funding credited for each collateral token, including when one side is empty?
- **Prove:** stateful fuzz with a ghost ledger of funding debits and credits (invariant 2). Differential: one update per interval vs one update per block must match within rounding.

### Liquidation math and the insurance fund
- **Mechanism:** the liquidation check omits accrued funding, borrow fee, close fee, or close price impact, so a position is underwater before it is liquidatable. A fixed `liquidationFeeUsd` exceeds the collateral of small positions, so liquidation reverts or the pool pays the keeper. Partial liquidation (close factor) can be repeated to collect the fee many times, or it leaves a remainder below `minCollateralUsd` that nobody liquidates. The keeper bonus is paid in full even when collateral is negative, so the insurance fund pays the bonus too.
- **Where to look:** `validateLiquidation`, `isPositionLiquidatable`, `getLiquidationPrice`, max-leverage partial decreases, `liquidationFeeUsd`, insurance-fund debit paths, the price side used (min for longs, max for shorts).
- **Ask:** at the boundary price, do the health check and the payout agree on every fee, and who pays when remaining collateral is below the keeper fee?
- **Prove:** fuzz price to the liquidation boundary ±1 wei; assert invariant 9. PoC: open the minimum position, move the price, liquidate; assert the pool's and insurance fund's loss is at most the position's shortfall.

### PnL socialization and LP-pool counterparty risk
- **Mechanism:** trader profit comes out of the LP pool. GMX v1 longs reserve the index token (`reservedAmounts`); if an increase path skips the reserve or a decrease releases more than it reserved, LP redemptions remove assets that back open profit. Caps per account are bypassed with many accounts; only global per-market caps bound pool exposure. An LP who redeems before a known adverse price update shifts the loss onto LPs who stay. GMX v1 (Jul 2025): cross-contract reentrancy through an `OrderBook` ETH refund reached `Vault.increasePosition` without the `ShortsTracker` update, skewed `globalShortAveragePrices`, and inflated GLP for mint-then-redeem.
- **Where to look:** `reservedAmounts`, `poolAmounts`, `guaranteedUsd`, `globalShortAveragePrices`, `getAum(maximise)` call sites, `cooldownDuration`, GMX v2 `reserveFactor`/`openInterestReserveFactor`/`MAX_PNL_FACTOR_FOR_TRADERS`, per-account vs global cap keys, every external call made while a leverage-enabled flag is set.
- **Ask:** after any sequence of opens and closes, does aggregate pool PnL equal the sum of position PnL, and can every open position be paid its maximum profit?
- **Prove:** stateful fuzz with a ghost sum over positions for invariants 3–5, using several actor accounts. PoC: an attacker `receive()` that calls each flag-gated function during execution; assert each reverts.

### ADL and deleveraging ordering
- **Mechanism:** when pool PnL exceeds a threshold, ADL force-closes profitable positions. Bugs: the trigger reads a different price than the one that set the threshold; the keeper chooses which position to close, and on-chain code enforces no ranking; ADL closes more than needed to restore `MIN_PNL_FACTOR_AFTER_ADL`; ADL charges price impact or fees a voluntary close would not; a trader front-runs a pending ADL to close at a better price, or reorders the ranking cheaply with a top-up.
- **Where to look:** `AdlUtils.updateAdlState`, `executeAdl`, `MAX_PNL_FACTOR_FOR_ADL`, the check that the PnL factor decreased after ADL, fee and impact flags on ADL decreases, settlement and delisting functions.
- **Ask:** which positions may be deleveraged, in what order, at which price, and does each ADL call reduce the pool's PnL factor without overshooting?
- **Prove:** test: push PnL over the threshold, execute ADL on the least profitable position; assert revert or that the documented ranking holds. Assert the pool PnL factor after ADL is between the target and the trigger.

### Negative, zero, and clamped prices
- **Mechanism:** Chainlink returns `int256 answer`; `uint256(answer)` turns a negative price into a value near `2**256`. A zero price divides by zero in `size / price`, so liquidation reverts for the whole market. `minAnswer`/`maxAnswer` bounds or protocol clamps (`max(price, floor)`) freeze the price while the real price leaves the band, so traders open or liquidations settle at a false price. Pyth prices use `int64 price` with `int32 expo`; scaling with the wrong sign of `expo` or ignoring `conf` misprices by orders of magnitude. A spread built as `price ± conf` can produce `minPrice > maxPrice` or a negative `minPrice`.
- **Where to look:** every cast from `int256`/`int64` to `uint256`, `answer > 0` checks, clamp logic, `expo` handling, PnL formulas `size * (exit - entry) / entry`, markets whose underlying can trade below zero.
- **Ask:** for each price input, what happens at `-1`, `0`, the clamp bound, and the clamp bound while the real price is 50% outside it?
- **Prove:** unit tests with a mock feed at `-1`, `0`, `minAnswer`, and a Pyth payload with `conf > price`; assert revert or documented handling, never a huge or zero price reaching PnL.

### Collateral haircut and mixed-collateral valuation
- **Mechanism:** accounts hold several collateral tokens valued at oracle price times a haircut. The haircut applies in the open check but not in the withdrawal or liquidation check; the liquidator seizes collateral at full value while the account was credited at the haircut; stablecoin collateral priced at a hardcoded 1.0 stays at par through a depeg; collateral correlated with the position (long ETH with ETH collateral) loses value twice in a crash. USD conversion as `amount * price / 10**decimals` with the wrong precision (GMX v1 uses 30-decimal USD) misvalues one token by orders of magnitude.
- **Where to look:** `tokenToUsdMin`/`usdToTokenMax`, collateral discount or weight parameters (`longWeightMaintenance`-style), every call site that values collateral, decimals constants, stablecoin price overrides.
- **Ask:** is one collateral unit valued identically, haircut included, in the open, withdraw, and liquidation paths?
- **Prove:** parameterized test over 6-, 8-, and 18-decimal mocks asserting `usdValue(1 unit) == price * haircut` on every path. Depeg scenario: stablecoin price drops 10%; assert account equity drops.

### Fee rounding on tiny positions
- **Mechanism:** `fee = sizeDelta * feeBps / 10000` rounds down to 0 for small `sizeDelta`, and the USD-to-token conversion of the fee rounds down again. Splitting one position into many small increases pays less fee or price impact than one increase. Positive price impact rounds up while negative impact rounds down, so open-close cycles extract value. A position below the minimum size, created through a partial decrease, has no profitable liquidation.
- **Where to look:** `getPositionFee`, `getPriceImpactUsd`, `usdToTokenMin` on fee amounts, `minPositionSize`/`minCollateralUsd` enforcement on decrease paths, rounding direction of each fee and impact term.
- **Ask:** what is the smallest accepted position, and does it pay a non-zero fee on open and on close?
- **Prove:** differential fuzz (SOL-Heuristics-17): N increases of `s/N` vs one increase of `s` must pay at least equal fees and impact. Loop of minimum open-close cycles at constant price; assert the trader's balance never grows (invariant 7).

### Cross-margin vs isolated-margin accounting
- **Mechanism:** cross-margin equity is collateral plus unrealized PnL minus fees across all positions. If unrealized profit counts toward withdrawable equity, a trader pumps the mark of one position and withdraws (Mango Markets, Oct 2022). A trader withdraws down to the maintenance edge so a small move hands a large position to the backstop vault (Hyperliquid ETH, Mar 2025). Isolated liquidation that reads cross equity, or cross liquidation that seizes isolated collateral, crosses the boundary. Switching a position between modes while it carries unsettled funding moves debt between buckets.
- **Where to look:** `getAccountEquity`/`getHealth`, initial vs maintenance margin in `withdrawMargin`, mode-switch functions, liquidation loops over an account's positions, which bucket pays fees.
- **Ask:** can unrealized profit leave the protocol before it is realized, and can a loss in one isolated position reach another position's collateral?
- **Prove:** PoC: open opposite positions on two accounts, move the mock mark price, withdraw from the winner; assert withdrawal is capped by initial margin on realized equity. Fuzz invariant 11 across mode switches.

## Checklist items to walk

- Oracles: SOL-Defi-Oracle-1, SOL-Defi-Oracle-2, SOL-Defi-Oracle-3, SOL-Defi-Oracle-4, SOL-Defi-Oracle-7, SOL-Defi-Oracle-8, SOL-Defi-Oracle-10, SOL-Defi-Oracle-11, SOL-Defi-Oracle-12, SOL-Defi-Oracle-13, SOL-Defi-Oracle-14, SOL-AM-PMA-1, SOL-AM-PMA-2
- Liquidation: SOL-Defi-Lending-1, SOL-Defi-Lending-2, SOL-Defi-Lending-3, SOL-Defi-Lending-4, SOL-Defi-Lending-5, SOL-Defi-Lending-6, SOL-Defi-Lending-7, SOL-Defi-Lending-8, SOL-Defi-Lending-11
- Order flow and ordering: SOL-AM-FrA-2, SOL-AM-FrA-3, SOL-AM-MA-1, SOL-AM-MA-3, SOL-AM-GA-1, SOL-AM-GA-2, SOL-Basics-Function-3, SOL-Defi-General-8, SOL-AM-SandwichAttack-1
- Liveness and refunds: SOL-AM-DOSA-1, SOL-AM-DOSA-2, SOL-AM-DOSA-4, SOL-AM-DOSA-6, SOL-Basics-Payment-1, SOL-Basics-AL-10, SOL-EC-7
- Reentrancy and ETH: SOL-EC-1, SOL-EC-13, SOL-AM-ReentrancyAttack-1, SOL-AM-ReentrancyAttack-2, SOL-Heuristics-14
- Math: SOL-Basics-Math-4, SOL-Basics-Math-5, SOL-Basics-Math-6, SOL-Basics-Math-8, SOL-Basics-Math-10, SOL-Basics-Math-12, SOL-Basics-Type-1, SOL-Heuristics-7, SOL-Heuristics-10, SOL-Heuristics-16, SOL-Heuristics-17
- Pool and accounting: SOL-Defi-General-1, SOL-Defi-General-3, SOL-AM-DA-1, SOL-Heuristics-13, SOL-AM-SybilAttack-1
- Access and signed prices: SOL-Basics-AC-2, SOL-Basics-VI-OVI-1, SOL-EC-14, SOL-Signature-1, SOL-Signature-4, SOL-Signature-5
- Admin: SOL-CR-2, SOL-CR-4, SOL-CR-7, SOL-AM-RP-1
- Token behavior: weird-ERC20 catalog ids A1, B1, B4, B6, D4, D5, E1, G4, G5 in [weird-erc20](skill://smart-contract-audit/references/weird-erc20.md). Map every collateral token and every LP pool asset to the catalog before evaluating payout and liquidation paths.
- Whole categories: [chain-specific](skill://smart-contract-audit/references/chain-specific.md) (L2 sequencer downtime, block time), [arbitrary calls and approvals](skill://smart-contract-audit/references/arbitrary-calls-approvals.md) (order callbacks, routers, forwarders), [upgradeability](skill://smart-contract-audit/references/upgradeability.md). Pair with the [lending playbook](skill://smart-contract-audit/references/playbooks/lending.md) for margin and liquidation, and the [vaults playbook](skill://smart-contract-audit/references/playbooks/vaults.md) for LP mint and redeem.

Proof tooling: [exploit PoC](skill://test-foundry/references/exploit-poc.md), [property catalog](skill://fuzz-echidna-medusa/references/property-catalog.md). Rate findings with [severity](skill://smart-contract-audit/references/methodology/severity.md).

## Precedent

- **Synthetix sKRW oracle, Jun 2019.** An off-chain price source reported the KRW rate about 1000x too high; a trading bot exchanged into sKRW and back for a large sETH profit before the feed was corrected. The class is an unbounded price input reaching execution.
- **GMX v1 AVAX, Sep 2022 (Avalanche).** Zero-price-impact execution at the oracle price let a trader move AVAX on the reference venues and close large positions against GLP for roughly $500K profit; GMX capped AVAX open interest afterward. https://www.coindesk.com/markets/2022/09/19/defi-trader-nets-over-500k-by-using-dex-gmx-to-manipulate-avalanche-token
- **Mango Markets, Oct 2022 (Solana).** Two attacker accounts held opposite MNGO perp positions; the attacker pumped MNGO on the spot venues behind the oracle, and unrealized profit counted as collateral for borrowing about $110M. The cross-margin class transfers directly to EVM code.
- **dYdX v3 YFI, Nov 2023.** A sharp YFI pump and crash liquidated large positions below their bankruptcy price; the insurance fund absorbed about $9M. The class is liquidation and insurance-fund sizing on a thin reference market.
- **Hyperliquid ETH, Mar 2025.** A trader withdrew margin from a large leveraged ETH long down to the maintenance edge; liquidation handed the position to the HLP backstop vault, which lost about $4M. Hyperliquid then lowered maximum leverage and raised the margin required after withdrawals.
- **Hyperliquid JELLY, Mar 2025.** A large short on a thin market was liquidated into the HLP vault, and the attacker then pumped the spot price; validators delisted the market and settled it at an admin-chosen price. The class is backstop exposure and settlement authority.
- **KiloEx, Apr 2025.** A forwarder left keeper-only position execution reachable by anyone; the attacker opened at a submitted low price and closed at a submitted high price across several chains.
- **GMX v1, Jul 2025 (Arbitrum).** Cross-contract reentrancy from an `OrderBook` ETH refund into `Vault.increasePosition` skipped the `ShortsTracker` update, skewed `globalShortAveragePrices`, and inflated GLP for mint-then-redeem; about $42M. https://blocksec.com/blog/gmx-incident-cross-contract-reentrancy-bypasses-a-four-year-old-guard
