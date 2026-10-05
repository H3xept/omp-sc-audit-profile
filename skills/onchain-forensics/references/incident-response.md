# Incident response

Load when an exploit is live or funds are still at risk. The goal is to **contain** first: stop further loss, then preserve evidence, then communicate. Attribution and root cause come after, in the incident-analysis branch of `skill://onchain-forensics`.

The agent's role is analyst and scribe. The protocol team signs, pauses, and posts. Hand them exact calldata, never keys you hold.

## 1. Confirm and scope (first minutes)

- [ ] **Confirm.** The tx succeeded (`cast receipt <hash> status`), value left the protocol (net-delta table from `Transfer` logs), and it is not a known admin operation (compare `from` with the role map from `roles.sh` and `proxy-info.sh`). Done when one tx hash shows unauthorised value movement.
- [ ] **Scope what is still exposed.** List every contract that shares the vulnerable code or the same implementation. The same factory, the same beacon, every chain with the same deployment, and forks of the protocol all count. Read balances at the latest block. Done when every exposed contract has a balance figure.
- [ ] **Watch for repeats.** Attackers rerun the same tx on the remaining pools and chains. Poll the attacker EOA's nonce (`cast nonce <eoa>`) and the vulnerable contracts' logs. Done when a monitor is running and its output lands in the incident log.

## 2. Contain

Prepared calldata saves minutes. For each lever, give the team the target, calldata, required signer, and expected effect.

- [ ] **Pause.** Find every pause lever and its holder: `pause()` and its role (`PAUSER_ROLE`, guardian), per-market or per-asset freezes, and bridge or messaging rate limits. Build calldata with `cast calldata 'pause()'`. A Safe holder needs threshold signatures, while a guardian EOA can act at once, so say which path is fastest. Done when every exposed contract is paused, or has a written reason why it cannot be (no pause function, or a timelocked pauser).
- [ ] **Check that pausing actually stops the path.** A `whenNotPaused` on `deposit` alone leaves `withdraw` or a callback open. Re-run the exploit tx on a fork after the pause, with `cast run` on the fork or the PoC from `skill://test-foundry/references/exploit-poc.md`. Done when the exploit reverts on a fork with the pause applied.
- [ ] **Cut the upgrade or role path if that is the vector.** For a compromised key: revoke the role (`revokeRole`), rotate Safe owners (`swapOwner`), or cancel queued timelock operations (`cancel(bytes32 id)` by a `CANCELLER_ROLE` holder). Done when `roles.sh` and `proxy-info.sh` no longer list the compromised address.
- [ ] **Rescue what remains** only through the protocol's own admin paths. A whitehat counter-exploit needs the protocol's explicit authorisation. The SEAL Safe Harbor framework is the standard pre-authorisation; check whether the protocol has adopted it.
- [ ] **Request freezes.** Stablecoin and RWA issuers can blocklist addresses (catalog D4 in `skill://smart-contract-audit/references/weird-erc20.md`), and exchanges can freeze deposits. Send the attacker addresses and tx hashes to issuers whose tokens sit at attacker addresses. Done when every issuer of a token the attacker holds has been sent the addresses.

## 3. Protect users

- [ ] **Approvals.** When the vulnerable contract pulls tokens through `transferFrom` from user allowances (routers, aggregators, vault zaps), every outstanding approval is exposure. Enumerate them from `Approval(address indexed owner, address indexed spender, uint256)` logs with `spender = <vulnerable contract>`, and check live `allowance(owner, spender)` for each. Tell users to revoke: `approve(spender, 0)` per token, or through revoke.cash or the explorer's token-approval page. For Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`), allowances live inside Permit2. Users revoke there with `lockdown((address token, address spender)[])` or `approve(token, spender, 0, 0)`, and invalidate pending signatures with `invalidateNonces`. Done when the published notice names the exact spender address, every affected chain, and the revoke action.
- [ ] **Frontend.** When the dapp could route users into the exploited path, take it down or block that path. When the incident is a frontend or DNS compromise, the contracts may be fine, and the approvals users signed to the malicious spender are the exposure.

## 4. Communicate

- [ ] **Escalate.** SEAL 911 (Telegram bot `@seal_911_bot`) is a free, 24/7 volunteer emergency line that can open a war room. Its War Room Guidelines assign the roles: operations, scribe, strategy lead, protocol lead.
- [ ] **Keep an incident log.** UTC timestamp, actor, action, and tx hash for every event: detection, pause, each attacker tx, each team action, each external notice. Done when every on-chain action in the incident has a log line.
- [ ] **First public notice** says what is known, what users must do (revoke, stop depositing), and that funds are being tracked. Exclude unconfirmed root cause and any unpatched detail that would help a copycat while contracts stay exposed. Done when the notice names affected contracts and chains and the user action.
- [ ] **Notify dependents.** Integrators, lenders that list the protocol's token as collateral, bridges carrying it, and oracle providers pricing it. A depegged receipt token spreads loss to every market that accepts it.
- [ ] **Message the attacker** on-chain only when the team decides to, with a bounty offer and a return address. Do it from a team-controlled address, and log the tx.

## 5. Recover and close

- [ ] **Root cause** comes from the incident-analysis branch: trace, value flows, attribution, and a fork PoC that reproduces the loss. Done when the PoC passes on the pre-fix fork and fails on the patched one.
- [ ] **Fix review.** Treat the patch as a fresh audit target. Re-run the PoC, add the property the exploit broke to the invariant suite (`skill://fuzz-echidna-medusa/references/property-catalog.md`), and check every sibling deployment from step 1.
- [ ] **Unpause plan.** Order matters. Upgrade first, then verify the bytecode (`scripts/bytecode-diff.sh` against the fix commit), then unpause. Watch the first transactions after unpause.
- [ ] **Post-mortem.** Timeline from the log, root cause at file:line, loss per token from the net-delta table, recovered amounts, and changes made. Mark anything not observed as `[INFERENCE]`.

## Sources

- SEAL 911 War Room Guidelines: https://frameworks.securityalliance.org/incident-management/playbooks/seal-911-war-room-guidelines/
- SEAL Incident Response Template for Web3 protocols: https://frameworks.securityalliance.org/incident-management/incident-response-template/overview/
- SEAL Whitehat Safe Harbor: https://frameworks.securityalliance.org/safe-harbor/overview/
- SEAL 911 bot: https://t.me/seal_911_bot
- Revoke.cash approval guide: https://revoke.cash/learn/approvals/how-to-revoke-token-approvals
