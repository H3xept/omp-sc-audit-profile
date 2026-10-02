# Vaults playbook

Load when: the code mints shares against pooled assets: ERC-4626 (`deposit`/`mint`/`withdraw`/`redeem`, `convertToShares`, `totalAssets`), ERC-7540 async requests (`requestDeposit`/`requestRedeem`), yield aggregators with strategies (`harvest`/`earn`/`invest`/`report`), or any `shares = assets * totalSupply / totalAssets` formula.

## Core invariants

1. `convertToShares` and `convertToAssets` round down, do not depend on the caller, and revert only on overflow (EIP-4626).
2. Rounding favors the vault on every path: `deposit` and `redeem` round down what the user gets; `mint` and `withdraw` round up what the user pays.
3. `previewDeposit(a) <= deposit(a)` shares, `previewMint(s) >= mint(s)` assets, `previewWithdraw(a) >= withdraw(a)` shares burned, `previewRedeem(s) <= redeem(s)` assets, each in the same transaction and including fees.
4. `deposit(a)` followed by `redeem(all shares)` in the same block returns at most `a` (no free value from a round trip, invariant holds for any interleaving of other users).
5. A direct transfer of assets to the vault raises every holder's share value pro rata and gives no single depositor more than their pro-rata part of it.
6. `totalAssets` equals assets the vault can actually realize for withdrawals (idle + strategy value net of unrealized loss), and it never counts the same asset twice across strategies.
7. `max*` functions return no more than the vault accepts at that moment and return 0 while that action is paused or disabled; `totalAssets` and `max*` never revert.
8. A strategy loss reduces share price for all holders at the same time; no holder can exit at the pre-loss price after the loss is realizable by anyone.
9. Async (ERC-7540): requests move Pending → Claimable → Claimed without skipping Claimable; requests with the same non-zero `requestId` become claimable together at the same rate.

## Where value moves

- **Entry:** `deposit`, `mint`, `requestDeposit`, router/zap deposit, `permit`-then-deposit helpers, direct `transfer` into the vault (donation), strategy `harvest`/`report` (profit in).
- **Exit:** `withdraw`, `redeem`, `requestRedeem` then claim, `emergencyWithdraw`, fee mint to treasury/manager, strategy `withdraw` from external protocol, `sweep`/`rescue`.
- **Privileged parameters:** strategy list and debt ratios, performance/management/withdrawal fees, deposit limits, `harvest`/`earn` callers (keeper vs public), profit unlock period, emergency shutdown, oracle for non-native assets, operator approvals in ERC-7540.
- **External dependencies:** the strategy targets (AMMs, lending markets, other vaults), price oracles used to value strategy positions, reward-token swaps on harvest, the asset token itself.

For each strategy, record how its value enters `totalAssets` (balance read, oracle, `convertToAssets` of another vault, LP math) and whether a single transaction can move that number.

## Bug classes

### First-depositor / donation inflation
- **Mechanism:** with tiny supply, the attacker deposits 1 wei, donates a large amount, and the next depositor's `assets * supply / totalAssets` rounds to 0 or 1 share; the attacker redeems the victim's deposit. A variant targets integrators: a near-empty vault used as collateral is inflated so its `convertToAssets` misprices it downstream.
- **Where to look:** `totalAssets()` reading `asset.balanceOf(address(this))`, absence of virtual shares/assets (OpenZeppelin `_decimalsOffset`, available since v4.9), absence of dead shares, deposit paths without `minShares`.
- **Ask:** what does a victim depositing `X` receive after an attacker front-runs with `deposit(1)` + `transfer(X)`? Can supply return to near-zero after launch (full redemptions, migrations)?
- **Prove:** Foundry PoC: attacker `deposit(1)`, `asset.transfer(vault, X)`, victim `deposit(X)`, attacker `redeem`; assert victim shares == 0 or attacker profit > 0. Property: `deposit(a) > 0 shares` whenever `a >= minDeposit`. OZ notes virtual shares make the attack unprofitable even at offset 0, but users still need slippage protection.

### Manipulable `totalAssets` (strategy valuation)
- **Mechanism:** `totalAssets` values a strategy position from a pool balance or spot price; the attacker skews the pool, deposits at the depressed share price, restores the pool, and withdraws at the true price (Harvest), or forces the vault to invest at a skewed rate via a public `earn()` (Yearn yDAI).
- **Where to look:** `estimatedTotalAssets`, `balanceOfPool`, `underlyingBalanceWithInvestment`, `get_virtual_price` vs `calc_withdraw_one_coin`, LP valuation, permissionless `earn`/`harvest`/`rebalance`.
- **Ask:** how far does one flash-loan-sized swap move `totalAssets`, and does any deposit or withdraw use that value in the same transaction?
- **Prove:** PoC: flash loan, skew the pool, deposit, unskew, redeem; assert profit after fees. Property: `totalAssets` changes by less than `epsilon` across a swap-and-revert sequence on the dependency.

### Rounding and preview mismatches
- **Mechanism:** `withdraw` rounds burned shares down (user pays too little), `mint` rounds assets down, preview functions omit fees or apply limits, `maxWithdraw` returns more than is withdrawable (strategy illiquid), so integrators revert or overpay.
- **Where to look:** `_convertToShares(assets, Math.Rounding.Floor|Ceil)` arguments at every call site; overridden `preview*`; fee-on-withdraw implementations.
- **Ask:** for each of the four entry points, which direction does each conversion round, and does the preview call the same path with the same rounding?
- **Prove:** property suite over the EIP-4626 MUST/SHOULD clauses (invariants 1–3, 7); `a16z/erc4626-tests` (https://github.com/a16z/erc4626-tests) is a ready template: extend `ERC4626Test` with the vault under test. See [property catalog](skill://fuzz-echidna-medusa/references/property-catalog.md).

### Loss and profit timing (sandwiching the share price)
- **Mechanism:** `harvest` books profit instantly, so an attacker deposits before and withdraws after it; a known pending loss lets insiders exit first; a withdrawal queue pays early redeemers at the pre-loss price and leaves the loss to the last.
- **Where to look:** profit unlock (Yearn v3 vault `profit_max_unlock_time`, tokenized strategy `profitMaxUnlockTime`, linear vesting), `report` ordering, `withdraw` that pulls from strategies in order and does not pass realized loss to the withdrawer, `maxLoss` parameters.
- **Ask:** can anyone observe a share-price jump one transaction before it lands, and can a withdrawer avoid a loss that has already happened on-chain?
- **Prove:** PoC: deposit, call public `harvest`, redeem in one transaction; assert profit. For losses: simulate a strategy loss, withdraw from one user, assert their share price equals the post-loss price.

### Fee accounting
- **Mechanism:** performance fee minted on unrealized or repeated gains (high-water mark missing), management fee accrued on stale time or before the share price update, fee shares minted after the price calc so depositors pay twice, withdrawal fee absent from previews.
- **Where to look:** `_accrueFees`, `_mint(feeRecipient, ...)` placement, `lastReport` / `highWaterMark` updates.
- **Ask:** does a sequence of deposit/withdraw around a fee accrual change the total fee collected?
- **Prove:** differential test: same economic history with frequent vs infrequent accrual calls should yield fees within rounding.

### Async vault (ERC-7540) request lifecycle
- **Mechanism:** pending requests counted in `totalAssets` (they should not earn or dilute until fulfilled), claimable assets priced at claim time rather than at fulfillment, operator approval allowing a third party to claim to its own receiver, requests for the same `requestId` fulfilled at different rates, `preview*` that does not revert for the async side.
- **Where to look:** `requestDeposit` (owner must be `msg.sender` or an approved operator), `requestRedeem` (shares leave the owner at request time), fulfillment functions, `claimable*Request` math, `setOperator`.
- **Ask:** between request and claim, which state can change the amount the user receives, and is that change in the spec's allowed set?
- **Prove:** stateful fuzz with request/fulfill/claim/cancel handlers; invariant: sum of claimable plus pending plus claimed equals sum of requested (in the request's unit).

### Strategy integration hazards
- **Mechanism:** strategy withdraw returns less than asked (slippage, fee, illiquidity) and the vault burns shares for the full amount; reward swap on harvest uses `amountOutMin = 0`; strategy approval left at max after removal; migration double counts assets.
- **Where to look:** `withdraw` loops over strategies, `_liquidatePosition` return values, `harvest` swaps, `migrateStrategy`, `revokeStrategy`.
- **Ask:** does the vault burn shares based on assets requested or assets received?
- **Prove:** mock strategy that returns 90% of requested; assert the withdrawer bears exactly the shortfall and other holders' share price is unchanged.

### Vault shares as collateral elsewhere
- **Mechanism:** a lending market or CDP prices the vault share with `convertToAssets` or `pricePerShare`, which a donation or strategy skew moves within one transaction. ResupplyFi lost its borrow cap this way.
- **Where to look:** any oracle adapter calling `convertToAssets`, `previewRedeem`, `getPricePerFullShare`; integer inversions such as `1e36 / price`.
- **Ask:** what does it cost to double this vault's reported share price, and what can be borrowed against it?
- **Prove:** PoC donating to the vault then borrowing in the dependent market. Cross-check with the [lending playbook](skill://smart-contract-audit/references/playbooks/lending.md).

### Withdrawal liquidity and `max*` honesty
- **Mechanism:** strategy funds are locked (lending utilization at 100%, unbonding period, LP lockup), but `maxWithdraw`/`maxRedeem` still return the full balance, so integrators that trust them revert; or the vault pays early redeemers from idle cash and leaves later redeemers with illiquid claims at the same share price (first-come run on a shared loss).
- **Where to look:** `maxWithdraw`/`maxRedeem` overrides (or their absence), withdrawal queues, `withdrawalQueue` ordering of strategies, `maxLoss` defaults.
- **Ask:** when only idle cash is liquid, what do `maxWithdraw(user)` and `redeem(maxRedeem(user))` return, and who bears the illiquid remainder?
- **Prove:** fork test against the real strategy at full utilization: call `redeem(maxRedeem(user))`; EIP-4626 requires it to succeed.

### Decimals and unit mismatches
- **Mechanism:** share decimals differ from asset decimals (virtual offset, wrappers over 6- or 24-decimal assets), and the vault, its oracle adapter, or an integrator mixes the two; fees computed in shares and charged in assets; `pricePerShare` scaled by `10**decimals()` of the wrong token.
- **Where to look:** `decimals()` override, `_decimalsOffset`, `pricePerShare`/`getRate` helpers, fee math, any hardcoded `1e18`.
- **Ask:** in every formula, are both operands in the same unit (shares vs assets) and the same scale?
- **Prove:** fuzz the property suite with a 6-decimal and a 24-decimal mock asset; mismatches show up as round-trip violations.

### Allowance, operator, and receiver paths
- **Mechanism:** `withdraw`/`redeem` with `owner != msg.sender` skip `_spendAllowance`, spend allowance in assets instead of shares, or let the caller choose `receiver` without owner consent; routers and zaps hold user approvals and expose a path to pull from arbitrary `owner` or `from`.
- **Where to look:** `withdraw(assets, receiver, owner)` and `redeem(shares, receiver, owner)` bodies, router `deposit(vault, to, amount, minShares)` helpers, `permit` + deposit flows, ERC-7540 `setOperator`.
- **Ask:** can any caller other than the owner, an allowance holder, or an approved operator move the owner's shares or redirect the assets?
- **Prove:** PoC: attacker calls `redeem(shares, attacker, victim)` with no allowance; assert revert. Pair with [arbitrary calls and approvals](skill://smart-contract-audit/references/arbitrary-calls-approvals.md) for routers.

### Emergency shutdown, migration, and upgrades
- **Mechanism:** `emergencyWithdraw` from a strategy realizes a loss that the vault does not book, so share price stays high and early exiters drain the remainder; strategy migration transfers tokens but not accounting (`totalDebt`, `lastReport`) or leaves the old strategy approved; a vault upgrade changes storage layout or `totalAssets` semantics under live shares.
- **Where to look:** `shutdown`, `emergencyExit`, `migrate`, `revokeStrategy`, `force_revoke_strategy` (Yearn v3 writes the strategy's remaining debt off as a loss), proxy upgrade hooks.
- **Ask:** after each admin rescue path, does `totalAssets` equal what the vault actually holds plus what it can still recover?
- **Prove:** test: shut down a strategy at a loss, then compare `convertToAssets(1e18)` before and after the next user action; the drop must land before any withdrawal at the old price.

## Checklist items to walk

- Shares and donations: SOL-Defi-General-3, SOL-Defi-General-4, SOL-Defi-General-7, SOL-Defi-General-8, SOL-AM-DA-1, SOL-Defi-FlashLoan-1, SOL-Defi-FlashLoan-2
- Price manipulation: SOL-AM-PMA-1, SOL-AM-PMA-2, SOL-AM-SandwichAttack-1, SOL-Defi-Oracle-13, SOL-Integrations-Uniswap-9
- Slippage on harvest and strategy swaps: SOL-Defi-AS-1, SOL-Defi-AS-2, SOL-Defi-AS-7, SOL-Defi-AS-11, SOL-Defi-AS-13, SOL-Defi-AS-14
- Math: SOL-Basics-Math-4, SOL-Basics-Math-5, SOL-Basics-Math-6, SOL-Heuristics-7, SOL-Heuristics-10, SOL-Heuristics-16, SOL-Heuristics-17
- Withdrawal liveness: SOL-AM-DOSA-1, SOL-AM-DOSA-2, SOL-AM-DOSA-4, SOL-AM-DOSA-6, SOL-AM-FrA-3
- Reentrancy: SOL-EC-1, SOL-EC-13, SOL-AM-ReentrancyAttack-1, SOL-Token-FE-7
- Integrations: SOL-Integrations-AC-2, SOL-Integrations-AC-3, SOL-Integrations-AC-7, SOL-Integrations-Balancer-1, SOL-Integrations-LSD-stETH-1
- Admin: SOL-CR-2, SOL-CR-4, SOL-CR-7, SOL-AM-RP-1
- Token behavior: weird-ERC20 catalog ids B1, B3, B4, B6, D4, D5, E1, G4, G5 in [weird-erc20](skill://smart-contract-audit/references/weird-erc20.md); rebasing and fee-on-transfer assets break `totalAssets` bookkeeping that tracks deposits instead of balances.
- Whole categories: [upgradeability](skill://smart-contract-audit/references/upgradeability.md), [arbitrary calls and approvals](skill://smart-contract-audit/references/arbitrary-calls-approvals.md) (routers, zaps, strategy `execute` hooks).

Proof tooling: [exploit PoC](skill://test-foundry/references/exploit-poc.md), [property catalog](skill://fuzz-echidna-medusa/references/property-catalog.md). Rate findings with [severity](skill://smart-contract-audit/references/methodology/severity.md).

## Precedent

- **Harvest Finance, Oct 2020.** Share price used the Curve Y pool's valuation of the strategy; the attacker skewed the pool with a large swap, deposited at the low price, swapped back, and withdrew. The vault's arbitrage check tolerated the skew. https://medium.com/harvest-finance/harvest-flashloan-economic-attack-post-mortem-3cf900d65217
- **Yearn yDAI v1, Feb 2021.** The attacker imbalanced Curve 3pool, deposited, and called the public `earn()` to push vault funds into the pool at a bad rate, then withdrew; slippage tolerance was loose and withdrawal fee was 0%. https://github.com/yearn/yearn-security/blob/master/disclosures/2021-02-04.md
- **ResupplyFi, Jun 2025.** Donation into a nearly empty ERC-4626 vault with 1 wei of shares inflated `convertToAssets`; the dependent oracle computed `1e36 / price` = 0 and LTV read as 0. https://paragraph.com/@resupply/resupply-crvusd-wstusr-market-post-mortem ; https://blocksec.com/blog/in-depth-analysis-and-reflections-on-the-resupply-protocol-attack-incident
- **Popsicle Finance, Aug 2021.** LP share transfers did not checkpoint fee accrual for sender and receiver, so the same shares collected fees repeatedly across addresses. https://blocksec.com/blog/the-analysis-of-the-popsicle-finance-security-incident
- **OpenZeppelin ERC4626 inflation mitigation.** Virtual shares and assets with `_decimalsOffset()` make the attack unprofitable; a larger offset raises its cost. https://docs.openzeppelin.com/contracts/5.x/erc4626
- **Specs:** EIP-4626 rounding, preview, and `max*` rules https://eips.ethereum.org/EIPS/eip-4626 ; ERC-7540 request lifecycle and operator rules https://eips.ethereum.org/EIPS/eip-7540
