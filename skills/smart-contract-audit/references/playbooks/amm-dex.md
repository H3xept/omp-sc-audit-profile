# AMM / DEX playbook

Load when: the code holds two or more token reserves and prices trades by an invariant (`x*y=k`, `sqrtPriceX96` with ticks, StableSwap `D`/`A`, weighted power math), mints LP shares against those reserves, is a Uniswap v4 hook, or integrates any of these through `swap`/`unlock`/pool callbacks.

## Core invariants

1. A swap never decreases the fee-adjusted invariant: for a v2-style pair, `(bal0*S - in0*f) * (bal1*S - in1*f) >= res0 * res1 * S^2`, where `S` and `f` are the same scale constants on both sides of the inequality.
2. Stored reserves never exceed token balances: `reserve_i <= token_i.balanceOf(pool)` after every external entry point.
3. A swap followed by its exact reverse leaves the trader with at most the original input (round-trip never profits).
4. Minting LP shares and burning them in the same block returns at most the deposited amounts; share value (`invariant / totalSupply`) is non-decreasing across swaps.
5. If every LP exits, the pool pays everyone without reverting and holds a balance `>= 0` of each token (solvency).
6. Concentrated liquidity: active `liquidity` equals the sum of `liquidityNet` over every initialized tick at or below the current tick, and `liquidityGross[t] == 0` exactly when tick `t`'s bitmap bit is clear.
7. The stored `tick` is the tick of the stored `sqrtPrice` (`getTickAtSqrtPrice(sqrtPrice) == tick`, with the documented exception when a downward swap ends exactly on a boundary: `tick == boundary - 1`).
8. Fees collectable by all positions sum to at most the fees the pool charged.
9. Every amount the pool receives is rounded up and every amount it pays is rounded down; N minimal operations never yield more than one aggregate operation.
10. StableSwap: the `D` and `y` solvers either converge within their iteration cap or revert; `D` is monotone in each balance; `A` moves only linearly between `initial_A` and `future_A` inside the ramp window.
11. Uniswap v4: when `unlock` returns, every currency delta of every address is zero; a hook moves value only through deltas the swapper's limits accept.
12. A TWAP over window `W` can be moved by `X` only by an attacker who holds the price for `W` and pays the arbitrage loss of doing so.

## Where value moves

- **Entry points:** `swap` (with `data` → flash swap), `mint`/`addLiquidity`/`join`, `burn`/`removeLiquidity`/`exit`, `flash`, `collect`, `donate` (v3 `flash` fee path, v4 `donate`), `initialize` (sets the first price), `sync`, batch swaps (Balancer `batchSwap`).
- **Callbacks the pool makes into caller code:** `uniswapV2Call`, `uniswapV3SwapCallback`/`MintCallback`/`FlashCallback`, v4 `unlockCallback`, every v4 hook callback, ETH sends via `raw_call`/`call` in Curve/Balancer exits, token hooks (catalog E1, E3).
- **Exit points:** `skim`, swap output, burn output, `collect`, protocol-fee withdrawal (`feeTo`, `setFeeProtocol`, admin fees), v4 `take`/`burn` of ERC-6909 claims, Balancer internal balance withdrawal (`manageUserBalance`).
- **Privileged parameters:** fee tier and protocol fee switch, `A` ramp (`ramp_A`, `stop_ramp_A`), rate providers and their cache duration, hook address and dynamic-fee setter, oracle cardinality, pause and recovery mode, pool factory allowlists.
- **External dependencies:** token behavior (catalog B1, B4, B5, D4, E1 in `skill://smart-contract-audit/references/weird-erc20.md`), rate providers (Balancer), the oracle consumers that read this pool's price, and the routers that call it.

## Bug classes

### Invariant check scaled inconsistently
- **Mechanism:** the k check compares fee-adjusted balances against old reserves using constants that no longer match. A fork that changes the fee denominator from 1000 to 10000 in the balance adjustment but keeps `1000**2` on the right side inflates the left side 100x, so a swap paying almost nothing passes.
- **Where to look:** `swap()` of every forked pair; any change to fee precision; custom fee-per-pair code; `getAmountOut` in the router versus the check in the pair.
- **Ask:** Do the router's quote, the pair's fee adjustment, and the invariant check all use the same `S` and `f`?
- **Prove:** fuzz `swap(amountOut)` with `amountIn` from the router quote minus 1 wei; invariant 1 must reject. A Halmos check over `(bal, in, out)` closes it.

### Reserves versus balances: donation, `sync`, `skim`
- **Mechanism:** pools price off cached reserves; anyone can transfer tokens and call `sync` to move the price with no swap, or `skim` to take any surplus. Consumers that read `balanceOf(pair)` or `getReserves()` as a price are manipulated within one transaction. Rebasing tokens (B4) make reserves stale, and `skim` captures the rebase; fee-on-transfer tokens (B1) break any path that credits the requested amount instead of the balance delta.
- **Where to look:** any function computing price, LP value, or collateral from `balanceOf(address(this))`; swap paths that assume `amountIn` arrived; LP valuation formulas `reserve * price / supply`.
- **Ask:** Can a donation plus `sync` change a value another contract trusts in the same transaction?
- **Prove:** donate, `sync`, call the consumer, assert its output moved; for B1/B4 use the catalog's mock recipes.

### First depositor, minimum liquidity, LP share inflation
- **Mechanism:** Uniswap v2 burns `MINIMUM_LIQUIDITY` (1000 wei of LP) on the first mint so share price cannot start at 1 wei. A fork or a custom pool that omits it lets the first LP mint 1 wei of shares, donate, and round every later depositor's shares to zero. Separately, whoever calls `initialize` on a v3/v4 pool sets the starting price; a protocol that auto-creates a pool and then adds liquidity at whatever price is current gets arbitraged.
- **Where to look:** first-mint branch (`totalSupply == 0`), share formula `amount * supply / reserve` rounding, `createAndInitializePoolIfNecessary` followed by `mint` with no price bound.
- **Ask:** What does the second depositor receive after the first deposits 1 wei and donates `D`?
- **Prove:** Foundry test: attacker mints minimum, donates, victim deposits; assert victim shares > 0 and victim can withdraw within rounding of their deposit (invariant 4).

### Tick crossing and liquidity accounting
- **Mechanism:** each swap step targets the next initialized tick; if the step reaches it, the pool crosses and applies `liquidityNet`. When the "can we reach the target" estimate and the final-price formula round differently, a step that is judged not to reach the target can still end past it: the tick updates, liquidity does not, and the stale liquidity is counted again on the reverse swap. KyberSwap Elastic broke here: `computeSwapStep` used `estimateIncrementalLiquidity` and `calcFinalPrice` with a rounding error, so with `swapAmount = amountToCrossTick - 1` the next sqrt price passed the target without a cross.
- **Where to look:** `SwapMath.computeSwapStep`, every fork that adds fee reinvestment or a second liquidity term, the tick-update expression after the step, `_updateLiquidityAndCrossTick`.
- **Ask:** Is the post-step price asserted to lie between the current price and the target in the swap direction? Do the reach-estimate and the final price use one formula with one rounding direction?
- **Prove:** stateful fuzz with invariants 6 and 7 checked after every swap; bias `amountIn` to `amountToCross ± 1` by binary search around each initialized tick.

### Fee-growth arithmetic that underflows by design
- **Mechanism:** Uniswap v3 computes `feeGrowthInside = global - below - above` and the `feeGrowthInside` deltas in positions with modular `uint256` wrap-around; the values are meaningful only as differences. A port to solc ^0.8 that drops `unchecked` reverts on valid states, freezing `burn`/`collect` for positions whose range was crossed in a certain order. A wrong `feeGrowthOutside` initialization convention (the tick at or below current takes `global`, otherwise 0) lets a fresh position claim fees it never earned.
- **Where to look:** `Tick.getFeeGrowthInside`, `Tick.cross`, `Position.update`, `tokensOwed` casts, any `unchecked` block in a v3 fork.
- **Ask:** Does every subtraction the original made modular still wrap, and is every subtraction that the original checked still checked?
- **Prove:** create two overlapping positions, swap back and forth across both ranges, then `burn` and `collect` both; the test fails on revert or on total collected exceeding fees charged (invariant 8).

### Rounding direction in price and amount math
- **Mechanism:** `SqrtPriceMath.getAmount0Delta/getAmount1Delta` take `roundUp`: amounts in round up, amounts out round down, and next-price helpers round so the price moves in the pool's favor. Custom math that rounds toward the trader leaks one wei per step, and an attacker multiplies the step count or shrinks balances until one wei is the whole pool. Balancer v2 Composable Stable Pools: `_swapGivenOut` upscales `amountOut` with a rate-provider scaling factor and rounds it down, which through StableMath rounds `amountIn` down too; the attacker first emptied the pool via an exit swap of BPT, then ran long batches of exact-out swaps that lowered the invariant and the BPT price. Bunni v2: `withdraw` decreased the idle balance by `balance.mulDiv(shares, supply)` (round down); 44 tiny withdrawals each rounded the same way and shrank the active balance from 28 wei to 4 wei, corrupting the liquidity estimate.
- **Where to look:** every `mulDiv`/`divDown`/`divUp`, `_upscale`/`_downscale`, rate-provider scaling factors, exact-out paths, share-proportional updates in withdraw, any state reachable at near-zero liquidity.
- **Ask:** For each division in swap/mint/burn, which party does the rounding favor, and does the same rounding compound across repeated minimal calls or at drained balances?
- **Prove:** round-trip property (invariant 3) and "N small = one large" (`SOL-Heuristics-17`) fuzzed from a drained-pool starting state; Halmos for single-step rounding direction of each helper.

### StableSwap solver and amplification
- **Mechanism:** `get_D` and `get_y` run Newton iterations to a tolerance of 1 wei with a fixed cap (255 in Curve). Curve's 3pool `get_D` returns the last iterate when the cap is hit; any implementation that does so instead of reverting prices trades off an unconverged invariant at extreme imbalance or tiny balances. Changing `A` changes `D` with no trade: during a ramp LP value and `get_virtual_price` can drop, and arbitrageurs extract the difference. Curve bounds a ramp by `MAX_A_CHANGE` (10x) and `MIN_RAMP_TIME` (1 day); forks that drop the bounds let an admin or a compromised key reprice the pool instantly.
- **Where to look:** solver loops and their exit condition, precision multipliers and rates applied before the solver, `ramp_A`/`stop_ramp_A`, `_A()` interpolation, any consumer that assumes `get_virtual_price` only rises.
- **Ask:** What does the solver return at balances `(1, 1e30)` and `(1, 1)`, and what can a trader extract over the course of a maximal `A` ramp?
- **Prove:** fuzz balances and `A` across the ramp window; assert solver convergence or revert, and LP value change bounded by the ramp's analytic delta.

### Read-only reentrancy into pool views
- **Mechanism:** a pool sends ETH (or calls a token hook) mid-exit while its view functions read half-updated state, and a third-party protocol prices collateral off those views from inside the callback. Curve: `get_virtual_price` during `remove_liquidity` sees `D` and `totalSupply` out of sync (dForce lost about $3.7M in 2023). Balancer v2: during `exitPool` with ETH out, BPT is burned before Vault balances update, so `getPoolTokens` plus `totalSupply` overprices BPT (Sentiment, 2023). In the same family, Vyper 0.2.15, 0.2.16, and 0.3.0 gave every `@nonreentrant` decorator its own storage slot regardless of key, so a shared lock never blocked cross-function reentry, and Curve pools compiled with those versions were re-entered from their ETH sends (July 2023).
- **Where to look:** pool exits that send native ETH or call token hooks before finishing writes; any integrator reading `get_virtual_price`, `getPoolTokens`, `getRate`, or `slot0` for valuation; Vyper pragma versions (see `skill://smart-contract-audit/references/evm-compiler.md`).
- **Ask:** Can an external call happen while a view returns a value that is false before and after the transaction, and does the integrator trigger the pool's lock before reading? Curve integrators call a state-changing nonreentrant function such as `withdraw_admin_fees`; Balancer integrators call `VaultReentrancyLib.ensureNotInVaultContext` or the empty `manageUserBalance` trick.
- **Prove:** attacker contract whose `receive()` calls the consumer's price function; assert the value differs from the pre- and post-transaction value by more than fees.

### Spot price and TWAP used as an oracle
- **Mechanism:** `slot0`, `getReserves`, and balance ratios move within one transaction. Buying token X from a v2 pool to raise its price by factor `r` costs `y*(sqrt(r) - 1)` of token Y plus fees; in a v3 range with liquidity `L` the token1 cost is `L*(sqrtP' - sqrtP)`. TWAPs cost holding the price for the window, so they fail when the window is short, the pool is thin, or the implementation lets a recent observation dominate: Inverse Finance's Keep3r oracle averaged from its last stored observation even when only one block had elapsed, so a read one block after the manipulated observation returned nearly the manipulated price. Uniswap v3 `observe` needs increased cardinality to cover the window; v4 has no built-in oracle, so any oracle is hook code.
- **Where to look:** any read of `slot0().sqrtPriceX96`, `getReserves`, `get_dy`, `getAmountsOut` used for valuation, liquidation, minting, or `minAmountOut`; TWAP window length, minimum `timeElapsed`, cardinality setup.
- **Ask:** What does it cost to move the read value enough to profit, and is that cost below the profit at current liquidity?
- **Prove:** fork test that flash-borrows, swaps, calls the consumer, unwinds, and asserts profit; for a TWAP, warp across the window while holding the price and compute the arbitrage loss.

### Uniswap v4: hook entry points callable by anyone
- **Mechanism:** hook callbacks are external functions; only a `msg.sender == poolManager` check (the `onlyPoolManager` modifier in v4-periphery's `ImmutableState`) stops a direct call with forged arguments. Cork Protocol built `CorkHook` on a v4-periphery `BaseHook` revision that predated the upstream authorization check (added 6 February 2025); the attacker's own hook contract reached `CorkHook.beforeSwap` with crafted `hookData` and bypassed the authorization checks in the hook and its `FlashSwapRouter`. Any pool can name any hook in its `PoolKey`, so a hook that serves "its" pools must reject foreign keys in `beforeInitialize`. The `sender` argument is the contract that called the PoolManager (usually a router), not the user.
- **Where to look:** every hook callback's first line and the pinned `BaseHook` revision; `beforeInitialize` key validation; uses of `sender`, `tx.origin`, or identities decoded from `hookData`.
- **Ask:** What happens if an attacker calls each callback directly, or creates a pool with attacker tokens pointing at this hook?
- **Prove:** direct-call test per callback expecting revert; a test that initializes an attacker pool on the hook and then exercises the victim pool.

### Uniswap v4: permission bits, deltas, and flash accounting
- **Mechanism:** the PoolManager calls only the callbacks whose flags are set in the lowest 14 bits of the hook address (`BEFORE_INITIALIZE_FLAG = 1 << 13` down to `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0`). A mined address missing a flag silently skips that callback's logic; a `*_RETURNS_DELTA` flag without its base flag fails `isValidHookAddress`; a proxy hook keeps its address bits while a new implementation changes which callbacks exist. The PoolManager skips hook calls when the hook itself is `msg.sender`, so logic that expects to observe the hook's own swaps never runs. In `unlock`, `take` creates debt and `settle` pays it; ERC20 payment requires `sync(currency)`, then the transfer, then `settle()`; native payment is `settle{value: x}()` and `settle` reverts with `NonzeroNativeValue` when ETH accompanies a synced ERC20. `beforeSwap` returns a `BeforeSwapDelta` and an LP-fee override; with `BEFORE_SWAP_RETURNS_DELTA_FLAG` the hook can replace the core curve entirely (negative `amountSpecified` is exact-input), which moves every bug class above into the hook's own math.
- **Where to look:** hook deployment salt and `validateHookPermissions` in the constructor; sign conventions in returned deltas (positive means the PoolManager owes the address); routers that settle from their own balance; repeated `settle{value:}` reading one `msg.value`; `clear` and ERC-6909 `mint`/`burn` of claims.
- **Ask:** Do the address flags match the implemented callbacks, does every path settle exactly what it takes, and can a hook's returned delta charge the swapper beyond their limit?
- **Prove:** an `IUnlockCallback` harness that drives each sequence; property: the hook's token balances plus ERC-6909 claims equal its internal accounting after every call.

### Uniswap v4: shared hook state, dynamic fees, liveness
- **Mechanism:** one hook serves many pools. State keyed by `PoolId` is isolated; global variables (accumulators, share totals, last price) let an attacker's pool mutate a victim pool's accounting. Dynamic fees require `fee == DYNAMIC_FEE_FLAG` (`0x800000`) at initialization; per-swap overrides take effect only with `OVERRIDE_FEE_FLAG` (`0x400000`) set and stay at or below `MAX_LP_FEE` (1,000,000 = 100%). A fee computed from manipulable state (spot volatility, a caller-supplied value in `hookData`) lets an attacker trade at zero fee and leave others at the maximum. A hook that reverts in `beforeRemoveLiquidity` freezes LP funds.
- **Where to look:** hook storage layout; `updateDynamicLPFee` callers; fee inputs; revert paths in remove-liquidity callbacks; owner switches that pause them.
- **Ask:** Which hook state is global, which pools can write it, and can LPs always exit?
- **Prove:** two-pool test (attacker pool, victim pool) on one hook asserting victim state is unchanged by attacker-pool actions; a liveness property that `removeLiquidity` succeeds in every reachable hook state.

### Integrator slippage, deadlines, sandwich and JIT liquidity
- **Mechanism:** a `minAmountOut` derived on-chain from the same pool, a zero or hardcoded slippage, `deadline = block.timestamp`, a hardcoded fee tier, or a check applied to an intermediate hop all leave the user sandwichable. JIT liquidity (add concentrated liquidity just before a large swap, remove just after) captures that swap's fees; any reward program that pays in-range liquidity per swap instead of per second of exposure pays JIT positions.
- **Where to look:** integrator swap wrappers, vault harvest/compound functions that swap rewards, liquidation swaps, LP incentive accounting.
- **Ask:** Who supplies the minimum, is it enforced on the final token received, and does reward accounting weight liquidity by time?
- **Prove:** fork test with a front-run swap, the victim transaction, and a back-run; the victim must revert once the move exceeds the user's tolerance.

## Checklist items to walk

- AMM/Swap: `SOL-Defi-AS-1`, `SOL-Defi-AS-2`, `SOL-Defi-AS-3`, `SOL-Defi-AS-4`, `SOL-Defi-AS-5`, `SOL-Defi-AS-6`, `SOL-Defi-AS-7`, `SOL-Defi-AS-8`, `SOL-Defi-AS-9`, `SOL-Defi-AS-10`, `SOL-Defi-AS-11`, `SOL-Defi-AS-12`, `SOL-Defi-AS-13`, `SOL-Defi-AS-14`.
- Flash loans and deposits: `SOL-Defi-FlashLoan-1`, `SOL-Defi-General-3`, `SOL-Defi-General-4`, `SOL-Defi-General-7`, `SOL-Defi-General-8`, `SOL-Defi-General-9`.
- Oracles: `SOL-Defi-Oracle-5`, `SOL-Defi-Oracle-13`, `SOL-AM-PMA-1`, `SOL-AM-PMA-2`.
- Uniswap: `SOL-Integrations-Uniswap-1`, `SOL-Integrations-Uniswap-2`, `SOL-Integrations-Uniswap-3`, `SOL-Integrations-Uniswap-4`, `SOL-Integrations-Uniswap-5`, `SOL-Integrations-Uniswap-6`, `SOL-Integrations-Uniswap-7`, `SOL-Integrations-Uniswap-8`, `SOL-Integrations-Uniswap-9`, `SOL-Integrations-Uniswap-10`.
- Balancer: `SOL-Integrations-Balancer-1`, `SOL-Integrations-Balancer-2`, `SOL-Integrations-Balancer-3`, `SOL-Integrations-Balancer-4`.
- Reentrancy and ordering: `SOL-AM-ReentrancyAttack-1`, `SOL-AM-ReentrancyAttack-2`, `SOL-EC-1`, `SOL-EC-13`, `SOL-AM-SandwichAttack-1`, `SOL-AM-MA-3`, `SOL-AM-DA-1`, `SOL-AM-FrA-1`.
- Math: `SOL-Basics-Math-4`, `SOL-Basics-Math-5`, `SOL-Basics-Math-9`, `SOL-Basics-Math-11`, `SOL-Heuristics-10`, `SOL-Heuristics-17`.
- Tokens: `SOL-Token-FE-6`, `SOL-Token-FE-7`; catalog `skill://smart-contract-audit/references/weird-erc20.md` (A1, B1, B4, B5, E1, G4).
- Whole files: `skill://smart-contract-audit/references/evm-compiler.md` (Vyper and compiler-version locks), `skill://smart-contract-audit/references/arbitrary-calls-approvals.md` (routers and callbacks).

Proof shapes: `skill://test-foundry/references/exploit-poc.md`, `skill://fuzz-echidna-medusa/references/property-catalog.md`. Rate findings with `skill://smart-contract-audit/references/methodology/severity.md`.

## Precedent

- **Uranium Finance, 2021:** fee scale changed to 10000 in the balance adjustment while the k check kept `1000**2`; pairs drained for about $50M. https://immunefi.com/blog/bug-fix-reviews/hack-analysis-uranium-finance-april-2021/
- **Inverse Finance, 2022:** Keep3r TWAP on a thin SushiSwap INV pool read with a tiny `timeElapsed` one block after manipulation; inflated INV collateral borrowed against. https://inspexco.medium.com/inverse-finances-incident-analysis-inv-price-manipulation-b15c2e917888
- **Curve LP oracle disclosure, 2022:** `get_virtual_price` read-only reentrancy during `remove_liquidity`; integrators patched by triggering the pool lock. https://www.chainsecurity.com/blog/curve-lp-oracle-manipulation-post-mortem
- **dForce, 2023:** Curve `get_virtual_price` read-only reentrancy used to mis-value collateral; about $3.7M. https://www.certik.com/blog/curve-conundrum-the-dforce-attack-via-a-read-only-reentrancy-vector-exploit
- **Sentiment, 2023:** Balancer `exitPool` with ETH out burned BPT before balances updated; BPT oracle overpriced during the callback. https://hackmd.io/@sentimentxyz/SJCySo1z2
- **Curve / Vyper, 2023:** `@nonreentrant` broken in Vyper 0.2.15, 0.2.16, 0.3.0; ETH pools re-entered. https://hackmd.io/@vyperlang/HJUgNMhs2
- **KyberSwap Elastic, 2023:** swap-step rounding let the price pass a tick without crossing it; liquidity double-counted on the reverse swap. https://blog.kyberswap.com/post-mortem-kyberswap-elastic-exploit/
- **Cork Protocol, 2025:** `CorkHook.beforeSwap` bypassed its authorization checks through forged `hookData`; combined with a rollover pricing flaw, the attacker extracted 3,761 wstETH. https://www.cork.tech/blog/post-mortem
- **Bunni v2, 2025:** round-down idle-balance decrease compounded over 44 tiny withdrawals after a flash-loan price push. http://blog.bunni.xyz/posts/exploit-post-mortem/
- **Balancer v2 Composable Stable Pools, 2025:** exact-out upscale rounding with rate providers at low liquidity lowered the invariant across a batch swap. https://medium.com/balancer-protocol/nov-3-exploit-post-mortem-51dcbeb6b020
