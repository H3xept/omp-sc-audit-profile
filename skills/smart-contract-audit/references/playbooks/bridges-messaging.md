# Bridges and cross-chain messaging playbook

Load when: the code sends or receives cross-chain messages (`_lzSend`/`_lzReceive`, `lzReceive`, `ccipSend`/`_ccipReceive`, Wormhole VAAs, Hyperlane `handle`, Axelar `_execute`, OP/Arbitrum native messengers), locks/burns tokens against a remote mint/release, or verifies remote state (validator signatures, merkle roots, light-client headers).

## Core invariants

1. Lock/mint conservation: for every asset, the wrapped supply summed over all destination chains plus in-flight credits is at most the balance in the source escrow.
2. Burn/mint conservation: total supply summed over all chains plus in-flight (burned, not yet minted) amounts is constant except for explicit protocol mints/burns.
3. Liquidity-pool conservation: LP claims on each chain are at most pool assets plus credits owed by remote pools; a remote credit is consumed exactly once.
4. At-most-once execution: the executed set, keyed by (srcChain, srcSender, nonce or messageId, dstChain, dstReceiver), only grows, and the key is marked before any external effect.
5. Authentic origin: a message executes only if (srcChain, srcSender) is in the receiver's peer allowlist and `msg.sender` is the messaging endpoint/router/messenger.
6. Verification threshold: no message is accepted with fewer than `threshold` distinct, currently-valid signers; changes to the signer set or threshold pass the same verification (or a stronger one).
7. No default proof: the zero root, an empty signature list, signer `address(0)`, threshold 0 and uninitialized mapping slots are never accepted as proof.
8. Isolation: a reverting message from user A never prevents execution of user B's message, unless ordering is a stated requirement with a documented unblock path.
9. Round-trip amount: the amount credited on the destination equals the amount debited on the source after decimal conversion; dust stays with the sender, never minted.
10. Failure recoverability: every destination failure leaves the value either retryable on the destination or refundable on the source, and never both.
11. Rate limit: outflow per (chain, token, window) never exceeds the configured cap, including bursts at window boundaries.
12. Config parity: peers, token mappings, decimals and pool types agree on both ends of every enabled path.

## Where value moves

- Source entry: `send`/`bridge`/`deposit`/`sendFrom`/`lock`. Record what is debited (`transferFrom` into escrow, `burn`, pool deposit), whether the recorded amount is the requested or the received amount, how `msg.value` splits between messaging fee and bridged value, and where excess fee is refunded.
- Destination exit: `lzReceive`/`_lzReceive`, `ccipReceive`/`_ccipReceive`, `process`/`execute`/`completeTransfer`/`withdraw(proof)`, finalize-withdrawal paths on native bridges.
- Recovery paths: `retryMessage`, CCIP manual execution, LZ V2 `skip`/`clear`/`nilify`/`burn`, LZ V1 `forceResumeReceive`, `refund`/`claimFailed`, admin `rescue`/`sweep`.
- Privileged parameters: validator/guardian set and threshold, DVN/oracle/relayer config, send/receive library, `setPeer`/`setTrustedRemote`, token mapping (local ↔ remote), rate limits, pausers, `enforcedOptions`, upgrade admins of the bridge and of every wrapped token.
- External dependencies: messaging layer contracts and their upgrade owners, off-chain relayers/executors/watchers, header relayers for light clients, per-chain finality configuration, token pools, the wrapped token's own admin.
- Mint authority map: for each wrapped token on each chain, list every address holding mint/burn rights. That list is the bridge's real trust boundary.

## Bug classes

### Default-value proof acceptance
- Mechanism: a mapping read for an unknown key returns 0 and the check treats 0 as valid. Nomad's Replica initialized `confirmAt[committedRoot = 0] = 1`; unproven messages read `messages[hash] == 0`, `acceptableRoot(0)` returned true, so any calldata passed `process`.
- Where: `initialize`/`reinitialize`, upgrade migrations, `prove`, `process`, `acceptableRoot`, signer lookups where `isSigner[ecrecover(...)]` meets `ecrecover` returning `address(0)`, thresholds derived as `signers.length * 2 / 3` while the set is empty.
- Question: for each verification function, what does it return on all-zero or empty input, and what state does each initializer and upgrade leave behind?
- Prove: call the destination entry with a fabricated message and an empty/zero proof on a fork at the post-upgrade block. Property: `executed(m) ⇒ dispatched(m)` with a ghost set of messages dispatched on the source harness.

### Signature and threshold verification
- Mechanism: duplicate signatures counted N times (no strictly-increasing signer order), recovered `address(0)` counted, malleable signatures bypass a `usedSignature[sig]` dedupe (SOL-Signature-2), digest omits chainId/bridge address/set epoch so a signature replays across deployments, rotated-out guardian sets stay valid.
- Mechanism (unauthenticated verifier input): Wormhole's Solana `verify_signatures` used the deprecated `load_instruction_at`, which did not check that the passed account was the real instructions sysvar; the attacker supplied a fake account and minted 120k unbacked wETH. EVM analog: a verifier, precompile result, or "already verified" record whose address or contents come from calldata or from a slot a weaker role can write.
- Where: `verifySignatures`, `_checkSignatures`, `parseAndVerifyVM`, guardian/validator set updates, any `verify(proof, verifierAddress)`.
- Question: can one key satisfy the threshold alone, and is every input the verifier trusts bound to the bridge's own state?
- Prove: unit tests with (a) the same signature repeated `threshold` times, (b) an invalid signature recovering to zero, (c) a valid signature from another chain's deployment, (d) a signature from an expired set.

### Key and validator-set compromise
- Mechanism: the threshold of keys is held by fewer independent parties than it appears. Ronin: 5-of-9, four keys held by Sky Mavis plus an Axie DAO allowlist that was never revoked. Harmony Horizon: 2-of-5 multisig. Multichain: assets left MPC-controlled addresses after its CEO, reported to control key material, was detained.
- Where: deployment config and on-chain state, not source. Read the live threshold and signer set with `skill://onchain-forensics`.
- Question: what is the blast radius of threshold keys signing a forged message — all escrowed TVL, or a capped amount per window?
- Prove: the trust finding rests on the observed config; report it as centralization (SOL-CR-4, SOL-CR-7) with the blast radius in assets, then test whether rate limits cap a forged release.

### Privileged-role injection through the message path
- Mechanism: the destination executor calls an attacker-chosen target, and the bridge's own privileged contracts are reachable as targets. Poly Network's `EthCrossChainManager` built the selector as `bytes4(keccak256(method ++ "(bytes,bytes,uint64)"))`; the attacker brute-forced a method name whose selector equals `putCurEpochConPubKeyBytes(bytes)` on `EthCrossChainData` (owned by the manager) and replaced the keeper keys.
- Where: generic `execute(target, data)` on the destination, payload fields like `toContract`/`method`, the messaging contract owning a data store or holding a minter role.
- Question: can a message target the bridge itself, its data store, a wrapped token's minter role, or any contract that trusts the bridge as `msg.sender`?
- Prove: craft a message with `target = privileged store`; 4-byte selector collisions are offline brute force. Walk `skill://smart-contract-audit/references/arbitrary-calls-approvals.md`.

### Replay and double execution
- Executed flag keyed on a hash that omits nonce or chain: two identical legitimate transfers collide, or one message executes on two destination chains where CREATE2 put the receiver at the same address.
- Executed flag written after the external call: a reentrant callback re-executes (SOL-EC-13).
- `retryMessage` executes the stored payload before deleting it; a failed message is both retryable on the destination and refundable on the source through an ack path.
- Once one bypass exists, everyone can copy it: after the first Nomad exploit, copycats replayed its calldata with their own recipient address.
- Prove: execute the same message twice, then on a second destination deployment; execute, fail, refund on source, then retry on destination.

### Sender authentication on the receiver
- LZ V2: `OAppReceiver.lzReceive` checks `msg.sender == endpoint` and `peers[origin.srcEid] == origin.sender`. Bugs live in contracts that override `lzReceive` instead of `_lzReceive`, override `allowInitializePath` to return true, or compare peers as `bytes32` with wrong padding.
- LZ V1: `lzReceive` must check `msg.sender == lzEndpoint` and `keccak256(_srcAddress) == keccak256(trustedRemoteLookup[_srcChainId])`; `_srcAddress` is `remote ++ local` packed.
- CCIP: router check plus allowlists on `sourceChainSelector` and decoded `sender` (SOL-Integrations-Chainlink-CCIP-1, -6).
- Native messengers: OP-style require `msg.sender == messenger && messenger.xDomainMessageSender() == l1Counterpart`; Arbitrum L1→L2 calls arrive from the aliased L1 address.
- Question: which of the endpoint, source chain and source sender does the handler check, and can an unset peer (zero) be matched?
- Prove: call the handler directly from an EOA; call it through the real endpoint from an unregistered source sender.

### Channel blocking and ordering
- LZ V1 blocking receivers: a revert in `lzReceive` stores the payload and blocks every later nonce on that path until retry or `forceResumeReceive` (SOL-Integrations-LayerZero-2, -5). An attacker triggers the revert cheaply: low destination gas in `adapterParams`, a recipient contract that reverts, an amount that overflows on the destination. `NonblockingLzApp` catches the revert, but the catch branch needs gas to store the payload (SOL-Heuristics-5).
- LZ V2: execution is unordered by default and a reverted `lzReceive` stays retryable. Ordered execution exists only when `nextNonce`/`_acceptNonce` are overridden and the sender adds the ordered-execution option; then one stuck nonce blocks the path, and endpoint `skip`/`clear`/`burn` advance the endpoint nonce without updating the OApp's local nonce mapping.
- CCIP: a failed message stays manually executable; on lanes that execute in order, a failed message blocks later messages from the same sender (SOL-Integrations-Chainlink-CCIP-8).
- Application ordering: message n+1 may execute before n (close before open, withdraw before deposit, config v2 before v1), or n may never execute.
- Question: can attacker A make the channel unusable for user B, and does any state transition assume delivery order?
- Prove: test that delivers messages out of order and forces one to revert, then asserts other users' messages execute.

### Destination gas and failure handling
- Sender-chosen gas (`adapterParams`, `options`, `extraArgs.gasLimit`) below what `_lzReceive`/`_ccipReceive` needs: the message reverts on arrival. LZ V2 `enforcedOptions` (per `eid` and message type) sets a floor; check it is configured for every path and message type.
- 63/64 rule inside a `try/catch` wrapper: the relayer picks a gas amount where the inner call runs out of gas and the outer catch succeeds, marking the message consumed with no effect (SOL-AM-GA-2). Return-data bombs from the inner call (SOL-EC-9).
- Retry with attacker-chosen parameters: who may call `retryMessage`, and can they change the payload, recipient or gas?
- Refunds: excess fee sent to `msg.sender` when `msg.sender` is a router lands in the router and goes to the next caller; a refund address without `receive()` reverts the whole send; native value delivered with the message is lost when the handler reverts permanently.
- Prove: run the destination handler with the minimum gas a sender can request and with the gas that leaves the inner call 1/64 short; assert the message stays retryable.

### Amount and decimals conversion
- OFT shared decimals: amounts travel as `uint64 amountSD = amountLD / 10^(localDecimals − sharedDecimals)` (default `sharedDecimals = 6`); `_removeDust` floors the debited amount. In `OFTCore`, `_toSD` is a plain `uint64(...)` cast, which truncates silently above `type(uint64).max` (about 1.8e13 whole tokens at 6 shared decimals), and `quoteOFT` reports `maxAmountLD = type(uint64).max` without enforcing it. Custom OFTs that debit `amountLD` but send `_toSD` without `_removeDust` burn the dust; a send whose `amountSD` exceeds uint64 credits a truncated amount.
- OFTAdapter (lock/unlock) source states only one adapter may exist per global mesh and assumes lossless transfers: a second adapter on another chain, or a fee-on-transfer/rebasing token behind it, breaks conservation (weird-erc20 B1, B4).
- Same asset with different decimals or addresses per chain (SOL-McCc-6; weird-erc20 G4, G5, F3, J4); CCIP pool-type mismatch (SOL-Integrations-Chainlink-CCIP-5).
- Prove: fuzz `amountLD` across `[0, 2^128]` and local decimals in `{6, 8, 18, 24}`; assert `credited ≤ debited` and `debited − credited < 10^(local − shared)`.

### Escrow, mint authority and deposit integrity
- Deposit records value that never moved. Qubit's legacy `QBridge.deposit` stayed callable after ETH moved to `depositETH`; with ETH's `tokenAddress = address(0)`, its `safeTransferFrom` performed a low-level call to a codeless address, which succeeds, so the deposit was recorded with no funds and xETH was minted on BSC (SOL-LL-3, SOL-EC-12).
- Off-chain relayers keyed on a deposit event or record that more than one function produces: every producer must move the value first, and deprecated entry points must be removed rather than left live.
- Burn-from without authorization: `sendFrom(from, ...)` debits `from` with no allowance check (SOL-Integrations-LayerZero-1 for ONFT `_debitFrom`).
- Wrapped token mintable by roles other than the verified receive path; mint reachable from a non-message entry.
- Liquidity-pool bridges: destination pool short on liquidity must leave the credit retryable, never dropped; credit/delta bookkeeping must decrement on consumption.
- Prove: invariant harness with a mock messaging layer that delivers, drops, reorders and duplicates; property: escrow balance ≥ Σ wrapped supply at every step.

### Finality, reorgs and optimistic windows
- Confirmations below the source chain's reorg depth: the deposit disappears after the destination mint (SOL-Integrations-LayerZero-7, SOL-Integrations-Chainlink-CCIP-4).
- Optimistic designs: who can dispute, whether watchers are permissionless, whether a disputed root is removed on every replica, and whether the window is measured with a clock comparable across chains (SOL-McCc-1).
- Light clients and proof libraries: BNB Token Hub (2022) accepted a forged IAVL proof whose extra inner-node fields did not affect the computed root. Ask whether the verifier enforces proof shape (op count, op types, single-sided branches), not only the root.
- Prove: feed the verifier a valid proof with an added or mutated non-root-affecting field; assert rejection.

### Pause, rate-limit and upgrade asymmetry
- Pause on the destination only: sources keep locking/burning; messages must stay retryable after unpause. Pause on the source only: in-flight messages still execute. A pause that reverts inside a V1 blocking receiver blocks the path.
- Rate limits applied outbound only, inbound unlimited; window decay arithmetic; per-`dstEid` limits bypassed by routing through a third chain.
- Upgrade keys: bridge contracts, wrapped tokens, and the OApp owner/delegate that sets send/receive libraries and DVNs. A delegate that can switch the receive library can forge any message (SOL-Integrations-LayerZero-6, SOL-McCc-7, SOL-CR-4). Diff every `initialize`/`reinitialize` argument in upgrade scripts: Nomad's zero root entered through one.
- Walk `skill://smart-contract-audit/references/upgradeability.md` and `skill://smart-contract-audit/references/chain-specific.md`.

## Checklist items to walk

- Multi-chain: SOL-McCc-1, SOL-McCc-2, SOL-McCc-3, SOL-McCc-4, SOL-McCc-5, SOL-McCc-6, SOL-McCc-7, SOL-McCc-8, SOL-McCc-9, SOL-McCc-10, SOL-McCc-11, SOL-McCc-12, SOL-McCc-13
- LayerZero: SOL-Integrations-LayerZero-1, SOL-Integrations-LayerZero-2, SOL-Integrations-LayerZero-3, SOL-Integrations-LayerZero-4, SOL-Integrations-LayerZero-5, SOL-Integrations-LayerZero-6, SOL-Integrations-LayerZero-7
- CCIP: SOL-Integrations-Chainlink-CCIP-1, SOL-Integrations-Chainlink-CCIP-2, SOL-Integrations-Chainlink-CCIP-3, SOL-Integrations-Chainlink-CCIP-4, SOL-Integrations-Chainlink-CCIP-5, SOL-Integrations-Chainlink-CCIP-6, SOL-Integrations-Chainlink-CCIP-7, SOL-Integrations-Chainlink-CCIP-8
- Signatures and proofs: SOL-Signature-1, SOL-Signature-2, SOL-Signature-3, SOL-Signature-4, SOL-Signature-5, SOL-AM-ReplayAttack-1, SOL-AM-ReplayAttack-2, SOL-HMT-3, SOL-HMT-4, SOL-Basics-VI-OVI-3
- Calls and gas: SOL-EC-5, SOL-EC-6, SOL-EC-7, SOL-EC-9, SOL-EC-12, SOL-EC-13, SOL-LL-3, SOL-AM-GA-2, SOL-Heuristics-5, SOL-AM-DOSA-4, SOL-AM-DOSA-6
- Init, upgrade, admin: SOL-Basics-Initialization-1, SOL-Basics-PU-5, SOL-Basics-VI-OVI-10, SOL-CR-2, SOL-CR-4, SOL-CR-6, SOL-CR-7, SOL-Timelock-1
- Tokens: SOL-Token-FE-3, SOL-Token-FE-6, SOL-Defi-General-1; weird-erc20 B1, B4, D4, F3, G4, G5, J4 in `skill://smart-contract-audit/references/weird-erc20.md`
- Whole categories: `skill://smart-contract-audit/references/chain-specific.md`, `skill://smart-contract-audit/references/arbitrary-calls-approvals.md`, `skill://smart-contract-audit/references/upgradeability.md`

PoC shapes: `skill://test-foundry/references/exploit-poc.md`. Conservation and at-most-once properties: `skill://fuzz-echidna-medusa/references/property-catalog.md`. Rate findings with `skill://smart-contract-audit/references/methodology/severity.md`.

## Precedent

- Poly Network, 2021: crafted method name collided with `putCurEpochConPubKeyBytes(bytes)`, letting a cross-chain call replace keeper keys. https://blocksec.com/blog/the-further-analysis-of-the-poly-network-attack
- Qubit QBridge, 2022: `deposit` with `tokenAddress = address(0)` succeeded via a low-level call to a codeless address; xETH minted with no ETH locked. https://blocksec.com/blog/when-safe-transfer-becomes-unsafe-lessons-from-the-q-bridge-security-incident
- Wormhole, 2022: deprecated `load_instruction_at` accepted a spoofed sysvar account, bypassing guardian signature verification; 120k wETH minted. https://wormholecrypto.medium.com/wormhole-incident-report-02-02-22-ad9b8f21eec6
- Ronin, 2022: five of nine validator keys compromised (four from one operator plus a stale Axie DAO allowlist). https://forta.org/blog/ronin-hack
- Harmony Horizon, 2022: 2-of-5 multisig keys compromised. https://medium.com/harmony-one/summary-of-the-harmony-horizon-bridge-incident-f9bd87c0c68e
- Nomad, 2022: upgrade initialized the trusted root to `0x00`; `acceptableRoot(0)` passed for every unproven message; copycats replayed the calldata. https://medium.com/nomad-xyz-blog/nomad-bridge-hack-root-cause-analysis-875ad2e5aacd
- BNB Chain Token Hub, 2022: forged IAVL proof passed root verification; 2M BNB minted. https://blog.verichains.io/p/binance-bridge-exploitation-preliminary
- Multichain, 2023: about $126M moved from MPC-controlled addresses after key custody failed. https://www.chainalysis.com/blog/multichain-exploit-july-2023/
- LayerZero `OFTAdapter` source, not an incident: one adapter per global mesh, lossless-transfer assumption. https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/oapp/contracts/oft/OFTAdapter.sol
- LayerZero `OFTCore` source, not an incident: `_toSD` truncating `uint64` cast, `InvalidLocalDecimals` when local decimals are below shared. https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/oapp/contracts/oft/OFTCore.sol
