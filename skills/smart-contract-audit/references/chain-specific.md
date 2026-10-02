# Chain-specific behavior

Profile-authored category (not part of the vendored Cyfrin checklist).

Total items: 18

## Sequencer and L2 liveness

### AUD-Chain-1: Does every price read on a sequencer-based L2 check the Chainlink L2 Sequencer Uptime Feed for status, apply a grace period after recovery, and handle `startedAt == 0`?
- **Risk:** The feed reports `answer == 0` for up and `1` for down, and `startedAt` is the time of the last status change. A check of `answer` alone accepts prices in the first block after a restart, when feeds are stale and the delayed-inbox backlog executes first. On Arbitrum, an uninitialized feed returns `startedAt == 0`, so `block.timestamp - startedAt` passes any grace check. On chains with no uptime feed, the check cannot be performed at all. SOL-Defi-Oracle-4 asks only "is the sequencer up".
- **Fix:** Revert when `answer == 1`, when `startedAt == 0`, or when `block.timestamp - startedAt <= GRACE_PERIOD`; Chainlink's example uses 3600 seconds. For each declared chain, confirm that a feed exists, and record the chains without one as a trust assumption.
- **Refs:** 1 case(s)
  - https://docs.chain.link/data-feeds/l2-sequencer-feeds

### AUD-Chain-2: Do time-based penalties (interest, liquidation eligibility, auction price decay, funding, expiry and claim deadlines) keep accruing while the sequencer is down?
- **Risk:** While the sequencer is down, most users cannot transact. Actors who force-include transactions through L1 still can, and on restart the delayed-inbox transactions run before new ones. Positions that crossed a threshold during the outage get liquidated, or Dutch auctions settle at the floor, before their owners can respond. Arbitrum's sequencer may also set `block.timestamp` up to 24 hours behind real time (AUD-Chain-4), so the outage's time jump arrives all at once.
- **Fix:** Pause liquidations and auctions while the uptime feed reports down, and for a grace period afterwards. Give users a repayment window before liquidation reopens. Exclude downtime from deadline arithmetic where the protocol can observe it.
- **Refs:** 1 case(s)
  - https://docs.chain.link/data-feeds/l2-sequencer-feeds

## Block context on L2s

### AUD-Chain-3: On Arbitrum, does any logic treat `block.number` as the L2 block (one-action-per-block guards, block-based vesting or interest, `blockhash` lookups, snapshot ids)?
- **Risk:** On Arbitrum, `block.number` returns an estimate of the L1 block number. It advances roughly every 12–15 seconds, and many L2 blocks share it. Duration math calibrated for L2 blocks runs at L1 cadence. "Once per block" guards permit many actions per value. Governance snapshots keyed by `block.number` cover many L2 blocks. The real L2 block number is `ArbSys(address(100)).arbBlockNumber()`. SOL-McCc-1 covers comparing across chains; this item covers what the opcode means on a single chain.
- **Fix:** Use `block.timestamp` for durations. Where L2 granularity matters, use `ArbSys.arbBlockNumber()`. Verify the cadence assumptions in a fork test on Arbitrum.
- **Refs:** 1 case(s)
  - https://docs.arbitrum.io/arbitrum-essentials/arbitrum-vs-ethereum/block-numbers-and-time

### AUD-Chain-4: On Arbitrum, can a sequencer-chosen `block.timestamp` decide an outcome inside a window shorter than about 24 hours behind or 1 hour ahead of real time?
- **Risk:** The Arbitrum sequencer sets `block.timestamp` from its own clock. It must be monotonic and may lag up to 24 hours or lead up to 1 hour. A force-included transaction gets the larger of its L1 delayed-inbox timestamp and the previous L2 timestamp. Short auctions, TWAP windows, oracle heartbeats and `deadline` checks therefore depend on a party that can skew time within those bounds. SOL-AM-MA-1 assumes miner drift of a few seconds.
- **Fix:** For each time-sensitive window, either size it above the skew bounds or record the trust in the sequencer in the threat model. Use oracle timestamps, not `block.timestamp`, to judge price staleness.
- **Refs:** 1 case(s)
  - https://docs.arbitrum.io/arbitrum-essentials/arbitrum-vs-ethereum/block-numbers-and-time

### AUD-Chain-5: Does any logic use `block.prevrandao`/`block.difficulty`, `block.coinbase`, `blockhash` or `block.basefee` with Ethereum semantics on an L2?
- **Risk:** `block.prevrandao`/`block.difficulty` is constant `1` on Arbitrum and constant `2500000000000000` on zkSync Era; on OP Stack it is the L1 RANDAO of the current L1 origin block, shared by every L2 block with that origin. `block.coinbase` is Arbitrum's fixed sequencer address `0xA4b000000000000000000073657175656e636572` (or the poster, for delayed messages), zkSync's bootloader `0x8001`, and OP Stack's sequencer fee wallet, so builder tips paid to `block.coinbase` go to the sequencer. On Arbitrum, `blockhash` is an L2-generated, cryptographically insecure pseudo-random value. On zkSync, `block.basefee` is set by the fee model rather than by EIP-1559 demand. SOL-AM-MA-2 covers randomness in general; here the values are constant or fully predictable.
- **Fix:** List every block-context opcode in scope, look up its value on each declared chain, and replace any opcode used for randomness, fee-routing or gas-budgeting with a chain-specific source (VRF, sequencer-independent fee logic, a hardcoded gas budget).
- **Refs:** 3 case(s)
  - https://docs.arbitrum.io/arbitrum-essentials/arbitrum-vs-ethereum/solidity-support
  - https://docs.optimism.io/op-stack/protocol/differences
  - https://docs.zksync.io/zksync-protocol/era-vm/differences/evm-instructions

## L1→L2 messaging

### AUD-Chain-6: Does an L2 contract that receives L1-originated calls compare `msg.sender` with the aliased address of the L1 sender, and with nothing else?
- **Risk:** On Arbitrum's delayed inbox (unsigned messages) and OP Stack's `OptimismPortal`, a call from an L1 contract arrives on L2 from `uint160(l1Address) + 0x1111000000000000000000000000000000001111`. That holds for `msg.sender` in the first frame, and on OP Stack also for `tx.origin`. A check against the raw L1 address never passes, or passes for an unrelated L2 contract deployed at that address. The two stacks treat EIP-7702-delegated L1 accounts differently: Arbitrum aliases them like contracts, while OP Stack leaves L1 EOAs and 7702-delegated accounts unaliased but aliases contracts that create and self-destruct in the same transaction. Logic that guesses from the sender's code whether it was aliased therefore gets edge cases wrong, and differently per chain. When a messenger contract relays the call, `msg.sender` is the messenger, and the original sender must be read from the messenger's cross-domain-sender accessor. SOL-McCc-8 covers messaging permissions in general.
- **Fix:** Compare `msg.sender` with `AddressAliasHelper.applyL1ToL2Alias(l1Sender)` for direct portal or inbox calls. For messenger relays, check `msg.sender == messenger` and the messenger's cross-domain sender. Fork-test both paths.
- **Refs:** 2 case(s)
  - https://docs.optimism.io/op-stack/protocol/differences
  - https://docs.arbitrum.io/how-arbitrum-works/deep-dives/l1-to-l2-messaging

### AUD-Chain-7: For Arbitrum retryable tickets, does the protocol stay correct if auto-redeem fails, if a third party redeems the ticket later in any order, or if the ticket expires?
- **Risk:** Auto-redeem fails when the gas or `maxFeePerGas` supplied is too low, or when the L2 call reverts. The ticket then stays redeemable by anyone for one week, can be extended, and on expiry refunds `callValue` to `callValueRefundAddress`. Separate tickets can be redeemed in any order and at any time. That breaks nonce-ordered message handlers, "deposit then stake" sequences sent as two tickets, and L2 state the L1 side assumed was updated. Because redeeming forwards all of the call's gas, a contract that issues several redeems must limit gas per redeem.
- **Fix:** Make every L2 handler order-independent and idempotent, keyed by a message id. Set the ticket's refund addresses, including `callValueRefundAddress`, to addresses the user controls on L2, remembering that a contract caller's address is aliased there. Monitor for failed tickets and redeem them before expiry.
- **Refs:** 1 case(s)
  - https://docs.arbitrum.io/how-arbitrum-works/deep-dives/l1-to-l2-messaging

## Gas and fees

### AUD-Chain-8: Does a gas-reimbursement or relayer-refund formula (`(startGas - gasleft() + overhead) * tx.gasprice`) run on an L2 that charges for L1 data?
- **Risk:** OP Stack charges an L1 data fee on top of execution gas, outside `gasleft()` accounting. Arbitrum converts the L1 calldata cost into L2 gas units (the "poster fee"), adds it to the transaction's gas charge, and reports it as `gasUsedForL1` in receipts. Either way, `startGas - gasleft()` measured inside the contract misses the L1 component, which is often the dominant cost. Relayers are under-reimbursed and stop serving, or a fixed `overhead` sized for Ethereum overpays users who submit with cheap calldata.
- **Fix:** Price the L1 component explicitly with the chain's gas oracle (Arbitrum `ArbGasInfo` or `NodeInterface`; OP Stack L1 fee estimation) or with a configurable per-chain premium. Fork-test with realistic calldata sizes.
- **Refs:** 2 case(s)
  - https://docs.optimism.io/op-stack/protocol/differences
  - https://docs.arbitrum.io/how-arbitrum-works/deep-dives/gas-and-fees

### AUD-Chain-9: Do hardcoded gas amounts (`transfer`/`send` stipends, `call{gas: N}`, `gasleft() > N` checks, gas forwarded to callbacks or precompiles) hold under each declared chain's gas schedule?
- **Risk:** Gas costs are chain-specific. zkSync Era meters execution differently: memory is priced linearly per byte, and value transfers go through the `MsgValueSimulator` system contract. In April 2023, Gemholic's sale contract on zkSync Era used `.transfer()`, and 921 ETH became stuck; zkSync announced a protocol-level gas-metering change to recover it. The P256 precompile costs 3450 gas under RIP-7212 on L2s and 6900 under EIP-7951 on Ethereum, so a budget sized for one fails on the other. SOL-Basics-Payment-6 and SOL-EC-6 describe the general risk; this item adds the per-chain check.
- **Fix:** Remove fixed gas values wherever possible. Where one is needed (for example a callback budget), make it per-chain configuration and measure it in fork tests on each chain.
- **Refs:** 3 case(s)
  - https://www.theblock.co/news/ecosystems/2023-04-07-zksync-unfreeze-millions-stuck-225364
  - https://docs.zksync.io/zksync-protocol/era-vm/differences/evm-instructions
  - https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-7951.md

## Precompiles

### AUD-Chain-10: Does code that calls the P256VERIFY precompile at `0x100` (WebAuthn, passkey and secure-enclave signers) require exactly 32 bytes equal to `1` in the returndata, and does every declared chain have the precompile?
- **Risk:** P256VERIFY returns 32 bytes of `0x…01` for a valid signature and empty returndata for an invalid one. Calling `0x100` on a chain without the precompile also succeeds and returns empty data. So a check on `success` alone accepts every signature, both on failure and on chains that lack the precompile. A check of returndata fails closed, but permanently locks passkey-only accounts on chains without it. RIP-7212 (on L2s) also omitted two checks that EIP-7951 adds: the point-at-infinity check, and the `r' ≡ r mod n` comparison. SOL-LL-4 covers precompile returndata size in general.
- **Fix:** Require `success && returndata.length == 32 && abi.decode(returndata, (uint256)) == 1`. For each declared chain, record whether the precompile exists, and fall back to a Solidity P256 verifier (or block deployment) where it does not.
- **Refs:** 1 case(s)
  - https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-7951.md

## Address identity across chains

### AUD-Chain-11: Does the protocol treat an address on one chain as controlled by the same party on another chain (treasury, multisig, peer contract, refund or recipient address)?
- **Risk:** A contract address is defined only on the chain where it was deployed. On 2022-05-27, 20M OP were sent to Wintermute's Ethereum Safe address on Optimism, where no contract existed at that address. Safe's Proxy Factory 1.1.1 deployment transaction was not protected by EIP-155, so the attacker replayed it on Optimism. They then called the factory's CREATE-based `createProxy` repeatedly with themselves as owner, until factory nonce 8884 produced Wintermute's address, and took the funds. The same failure applies to bridged refunds, LayerZero or CCIP peer configuration, and cross-chain fee recipients. SOL-AM-ReplayAttack-2 covers signatures, not address ownership.
- **Fix:** Before sending funds or trust to an address on chain B, confirm that the contract is deployed on B with the expected code and owners. Use CREATE2 factories whose salt commits to the owner set. Store remote peers explicitly per chain id.
- **Refs:** 1 case(s)
  - https://mirror.xyz/banteg.eth/iZAsBNL3j_5NIAY2Erav1r7Q4ecc7SC76AfMjyScs34

## zkSync Era (EraVM)

### AUD-Chain-12: On zkSync Era, does any code precompute CREATE or CREATE2 addresses with the Ethereum formula, or deploy contracts from bytecode handled in assembly?
- **Risk:** EraVM derives addresses as `keccak256(keccak256("zksyncCreate2") ‖ sender ‖ salt ‖ bytecodeHash ‖ keccak256(input))[12:]`, and CREATE uses `keccak256("zksyncCreate")` with the sender's nonce. Ethereum-formula address predictions (`Clones.predictDeterministicAddress`, Uniswap-style `pairFor` init-code hashes, counterfactual wallet addresses) therefore point to addresses that stay empty on EraVM, and funds or approvals sent there are lost. `create`/`create2` in assembly works only for the exact `type(T).creationCode` pattern that zksolc recognises. Factories that deploy arbitrary bytecode never work, and `type(T).runtimeCode` fails to compile. Only contracts deployed as EVM bytecode, through the EVM bytecode interpreter, keep Ethereum derivation. SOL-McCc-10 names zkSync compatibility generically.
- **Fix:** On EraVM, derive addresses with the zkSync formula, or read them from the factory's return value. Replace assembly factories with `new T{salt: s}()`. Fork-test deployment and address prediction on zkSync.
- **Refs:** 1 case(s)
  - https://docs.zksync.io/zksync-protocol/era-vm/differences/evm-instructions

### AUD-Chain-13: On zkSync Era, does any check depend on `extcodehash` semantics (`== 0` for "account does not exist", `== keccak256("")` for "no code", or equality with `keccak256` of known bytecode)?
- **Risk:** EraVM's EXTCODEHASH ignores the account balance. It treats every address in precompile space, plus `0x00`, as an existing empty account. For contracts it returns a versioned bytecode hash rather than the EIP-1052 `keccak256(code)`. Codehash allowlists, "is this a fresh address" checks and clone-verification logic that work on Ethereum therefore give different answers.
- **Fix:** On EraVM, compute expected hashes from the deployed contracts, or replace codehash checks with explicit registries.
- **Refs:** 1 case(s)
  - https://docs.zksync.io/zksync-protocol/era-vm/differences/evm-instructions

### AUD-Chain-14: On zkSync Era, does constructor assembly execute `return` or `stop`, or does code rely on `codecopy`, `extcodecopy`, `selfdestruct`, `callcode` or `msize`?
- **Risk:** EraVM stores immutables in the `ImmutableSimulator` system contract, and the constructor returns the array of immutables. An assembly `return`/`stop` in a constructor therefore leaves every immutable uninitialized: owner, token and oracle addresses read as zero. `extcodecopy`, `selfdestruct`, `callcode` and runtime `codecopy` (in the new codegen) fail at compile time. Memory grows per byte rather than per word, so `msize`-dependent logic and out-of-bounds memory panics differ from Ethereum.
- **Fix:** Remove constructor-level assembly terminators. Read immutables back in a post-deployment test on zkSync. Compile with zksolc in CI for every EraVM target.
- **Refs:** 1 case(s)
  - https://docs.zksync.io/zksync-protocol/era-vm/differences/evm-instructions

## Chain-specific assets

### AUD-Chain-15: On a declared chain where the native currency also has an ERC-20 interface (weird-erc20 F2/J3), can one deposit be credited through both `msg.value` and the token path?
- **Risk:** The same balance moves through `msg.value` and through the token contract's `transferFrom`. A function that accepts both, or a multicall that combines them, can credit the same value twice. See `skill://smart-contract-audit/references/weird-erc20.md` (F2, J3) for the chains and the property to assert.
- **Fix:** Assert that the value is "not creditable twice", as the F2 property states: measure balance deltas across both entry paths in one fork test on each affected chain.

### AUD-Chain-16: Is the token configuration per chain (addresses, decimals, rebasing or yield mode, oracle mapping) reviewed for each declared chain instead of copied from Ethereum?
- **Risk:** The same asset exists at many bridged addresses with diverging behavior (weird-erc20 F3, J4). On Blast, WETH and USDB rebase by default, so the rebasing behavior B4 applies to WETH itself (J2). An allowlist, oracle map or decimals constant copied from Ethereum therefore misprices or mis-accounts the asset. See `skill://smart-contract-audit/references/weird-erc20.md`. SOL-McCc-6 covers decimals only.
- **Fix:** Build a per-chain table (token address, canonical bridge, decimals, rebasing or yield mode, oracle feed) and fork-test each row against the chain's live contract.

## Oracle freshness on L2 feeds

### AUD-Chain-17: Does any Chainlink validation treat `answeredInRound >= roundId` as a freshness check, and is staleness measured per feed rather than against one global threshold?
- **Risk:** On OCR feeds — every Chainlink feed deployed since 2021 — `answeredInRound` is deprecated and equals `roundId` on every answer, so the comparison passes for arbitrarily stale data. A copy-pasted validation of `price > 0` plus `answeredInRound >= roundId` accepts a price that is hours old. The symmetric bug is one hardcoded staleness threshold for every feed: a threshold below a feed's heartbeat reverts between updates and DoSes borrows, withdrawals, and liquidations; a threshold above it accepts stale prices on fast feeds. Heartbeats differ per feed and per chain (the same pair updates faster on Ethereum than on an L2).
- **Fix:** Freshness is `block.timestamp - updatedAt <= heartbeat`, with the heartbeat stored per feed at listing time. Drop the `answeredInRound` comparison entirely.

### AUD-Chain-18: Does the code handle a Chainlink answer clamped at the aggregator's `minAnswer` or `maxAnswer`?
- **Risk:** Off-chain aggregators with an access controller can refuse answers outside `[minAnswer, maxAnswer]`; in a crash the feed then reports the floor while the market trades far below it. In May 2022 the LUNA/USD feed kept reporting about $0.10 while LUNA fell orders of magnitude lower; Venus and other BNB Chain lenders accepted the clamped price, overvalued LUNA collateral, and took on about $11M of bad debt. Newer feed contracts removed the bounds, but long-tail feeds on many chains still carry them.
- **Fix:** At listing, check whether each feed enforces bounds (read `minAnswer`/`maxAnswer` on the aggregator). Where it does, reject an answer equal to a bound or fall back to a second oracle; never size a position from a clamped price.
