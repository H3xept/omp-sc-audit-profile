# NFT marketplace, mint and NFT-finance playbook

Load when: the code fills signed orders for ERC-721/ERC-1155 (`fulfillOrder`, `matchOrders`, `buyItem`, `acceptOffer`, Seaport/Wyvern/LooksRare-style structs), runs auctions or Dutch/English sales, mints collections (`mint`, `allowlistMint`, `reveal`, ERC721A), pays royalties (`royaltyInfo`), or uses NFTs as collateral, vault shares or fractions (lending, fractionalization, NFT AMMs).

## Core invariants

1. Order authority: an order fills only with a valid signature (or on-chain approval) from the current owner of the offered items, inside its validity window, at a counter/nonce the offerer has not invalidated.
2. Fill bound: the filled fraction of an order never exceeds 1, and the price paid for any partial fill is at least the signed price pro-rata, rounded in the offerer's favor.
3. Payment conservation per fill: buyer pays exactly seller proceeds + royalty + protocol fee (+ any signed tips); no leftover stays in the marketplace contract unless it is intended escrow.
4. Atomic exchange: an NFT leaves the seller only in the same transaction in which the seller's consideration is paid, and vice versa.
5. Quantity semantics: for ERC-721, quantity is exactly 1 (or the field is ignored and price is still charged in full); for ERC-1155, the amount transferred equals the amount priced.
6. Approval scope: the marketplace moves a token only as directed by a valid order or by the owner; an approval-for-all to the marketplace is never usable by a third party.
7. Auction: the winning bidder pays the highest valid bid; every outbid or losing bidder can withdraw exactly their bid; the seller can claim proceeds after settlement.
8. Mint caps: total supply ≤ max supply; per-signature/per-allowlist-entry mints ≤ allocation; each id is minted once.
9. Reveal fairness: the token-id → metadata assignment is fixed by a source no minter can predict or influence before minting closes.
10. NFT collateral: a loan is liquidatable before debt exceeds collateral value under the configured oracle, and liquidation pays the lender at least the debt when a bid exists.
11. Fraction redemption: fractions outstanding × redemption price ≤ assets held for redemption, and a buyout never transfers the NFT without paying every fraction holder.

## Where value moves

- Entry points: order fulfilment and matching, offer acceptance (including collection/criteria offers), `bid`/`settle`/`withdrawBid`, `mint` variants, `cancel`/`incrementCounter`/`incrementNonce`, deposit into lending or fraction vaults, buyout start/bid/redeem, NFT AMM swaps.
- Exit points: transfers of NFTs out of escrow or through approvals, payment splits to seller/royalty receiver/fee recipient, refunds of excess `msg.value`, auction refunds, `withdraw` of mint proceeds, liquidation transfers.
- Privileged parameters: fee recipient and fee bps, royalty overrides/registries, allowed currencies and collections, zones/validators, signer key for mint allowlists, mint price/phase/max supply, reveal provenance/VRF config, oracle source and liquidation thresholds for NFT lending, pausers, upgrade admins.
- External dependencies: ERC-721/1155 implementations of listed collections (any contract that claims the interface), ERC-2981 `royaltyInfo` of each collection, payment tokens (`skill://smart-contract-audit/references/weird-erc20.md`), VRF coordinator, floor-price oracles.
- Approval surface: list every contract users approve (`setApprovalForAll`, ERC-20 approvals to the marketplace or a conduit) and every path that can trigger a transfer from those approvals.

## Bug classes

### Stale and uncancelled orders
- Mechanism: an off-chain signed listing stays valid after the user believes it is gone. OpenSea (Jan 2022): listings cancelled only in the UI (or abandoned when the NFT moved away) became fillable again when the NFT returned to the same wallet; e.g. a BAYC sold at its old listing price. Orders without `endTime`, without a counter, or cancellation that only removes the order from an off-chain database.
- Where: order struct fields (`startTime`, `endTime`, `counter`/`nonce`, `salt`), `cancel`, `incrementCounter`; Seaport bulk-cancels by `incrementCounter` and since 1.2 increments by a quasi-random amount derived from the previous blockhash so a pre-signed far-future counter is impractical.
- Question: after each action a user can take to "remove" a listing (transfer away, revoke approval, UI cancel), can the signed order still fill when conditions return?
- Prove: sign order → transfer NFT away → transfer back → fill; assert revert. Property: invariant 1.

### Signature binding and EIP-712 struct coverage
- Mechanism: a signed field is missing from the type hash or digest, so a filler changes it: currency, recipient, fee/royalty split, quantity, criteria root, zone, chainId/verifying contract (SOL-Signature-1). Malleable signatures defeat `usedSig[sig]` dedupe (SOL-Signature-2); `ecrecover` returning `address(0)` matches an unset signer (SOL-Signature-3); ERC-1271 sellers whose `isValidSignature` accepts any digest.
- Where: `ORDER_TYPEHASH`, `hashOrder`, `abi.encodePacked` of dynamic arrays (SOL-Basics-VI-SVI-4), nested struct hashing order, bulk-order merkle verification.
- Question: which order fields affect who pays what to whom, and is each one inside the signed digest?
- Prove: for each economic field, mutate it after signing and fill; assert revert.

### Partial fills and criteria offers
- Mechanism: fill fraction tracked per order but rounding lets a buyer take items for less than pro-rata (repeated fills of 1 unit when price/denominator truncates; SOL-Basics-Math-5); `numerator/denominator` updates that reset filled amounts; collection offers (Seaport `identifierOrCriteria = 0` means any id, nonzero is a merkle root of ids) filled with the worst item in the collection, or with an id the root does not contain because the resolver skips the proof (SOL-HMT-4, SOL-HMT-5).
- Where: `_validateOrderAndUpdateStatus`-style fill tracking, `CriteriaResolver` handling, trait offers validated off-chain only.
- Question: can a filler obtain more units, or a worse id, than the offerer priced?
- Prove: fuzz partial-fill sequences; property: Σ units transferred × signed unit price ≤ Σ paid, and filled ≤ total.

### ERC-721 / ERC-1155 quantity confusion
- Mechanism: one code path serves both standards. TreasureDAO marketplace (Mar 2022, Arbitrum): `buyItem` computed `totalPrice = pricePerItem * _quantity`; with `_quantity = 0` the price was zero while the ERC-721 `safeTransferFrom` ignored quantity and delivered the NFT.
- Where: functions that branch on `supportsInterface`, a `quantity`/`amount` parameter that the ERC-721 branch ignores, listings that track `quantity` remaining (SOL-Token-NfE1-5, SOL-Token-NfE1-6).
- Question: for each standard, does the price charged equal the amount actually transferred, including 0 and amounts above the listing?
- Prove: buy an ERC-721 listing with quantity 0 and 2; assert revert or full price.

### Receiver-hook reentrancy
- Mechanism: `safeTransferFrom`/`_safeMint` call `onERC721Received`/`onERC1155Received`/`onERC1155BatchReceived` on the recipient, which re-enters before state is final (SOL-Token-NfE1-2, SOL-Token-NfE1-3, SOL-Defi-LSD-3). Omni Protocol (Jul 2022): NFT withdrawal and liquidation paths sent the NFT via `safeTransferFrom` before collateral state was cleared, so the callback re-borrowed against collateral being removed. Revest Finance (Mar 2022): the ERC-1155 receive hook during `mintAddressLock` re-entered `depositAdditionalToFNFT`, which did not check that the FNFT id existed, and overwrote deposit accounting for a large-supply id.
- Where: mint loops that call `_safeMint` per iteration with supply counters updated after the loop (mint above max supply), auction settlement, escrow withdrawal, loan repayment/liquidation, fraction redeem; any function that sends an NFT before writing its final state (SOL-AM-ReentrancyAttack-1).
- Question: at each NFT send, what state would a re-entrant call see, and which functions lack a shared reentrancy lock?
- Prove: receiver contract that re-enters every public function from the hook; assert invariants 3, 8 and 10.

### Approval abuse and phishing surface
- Mechanism: the marketplace or a conduit holds `setApprovalForAll` from many users, so any path that lets a caller choose `from` drains them. Arbitrary `call` helpers in the marketplace (`skill://smart-contract-audit/references/arbitrary-calls-approvals.md`); `transferFrom(from, …)` with `from` taken from calldata without checking the order signer (SOL-Token-NfE1-4); orders signed for legacy contracts that still hold approvals. OpenSea/Wyvern (Feb 2022): users signed Wyvern orders through a phishing email; attackers filled them with the users' existing approvals to take 254 NFTs.
- Where: `from` parameters, batch transfer helpers, migration contracts, legacy exchange versions still approved, `permit`-style NFT approvals (ERC-4494) with weak deadlines.
- Question: for each transfer the contract can perform, who authorized this specific `from`, item and recipient?
- Prove: call every transfer-capable function as an attacker with a victim that has approved the marketplace; assert no victim asset moves.

### Payment splitting, royalties and fees
- Mechanism: ERC-2981 is signal-only: the collection's `royaltyInfo(tokenId, salePrice)` returns whatever receiver and amount its code chooses, including more than `salePrice`, so a marketplace that pays it unbounded underflows the seller's proceeds or reverts every sale; a receiver contract that reverts on ETH blocks sales (use pull payments, SOL-AM-DOSA-1); a collection's `royaltyInfo` that consumes all gas or returns a bomb (SOL-EC-7, SOL-EC-9). Royalties computed on the post-fee amount or per unit in a batch round to zero (SOL-Basics-Math-2). Royalties are bypassable by OTC transfers or wrapper contracts; treat enforcement claims as best-effort.
- Native ETH: excess `msg.value` not refunded, `msg.value` reused across a batch loop (SOL-Basics-Payment-1 and siblings), ETH fill paying ERC-20 orders.
- ERC-20 payment: fee-on-transfer, no-return and blocklisted currencies (weird-erc20 B1, A1, D4); a blocklisted seller blocks auction settlement.
- Question: does every fill pay buyer amount = seller + royalty + fee exactly, capped and in a fixed order that a malicious recipient cannot break?
- Prove: fuzz `royaltyInfo` returning [0, 2×price] and reverting receivers; property: invariant 3 and no stuck ETH.

### Auction settlement and refunds
- Mechanism: refunds pushed in a loop let one reverting bidder block everyone (SOL-AM-DOSA-1, SOL-AM-DOSA-4). Akutar (Apr 2022): `processRefunds` pushed refunds with `call` in a loop; separately `claimProjectFunds` required `refundProgress >= totalBids`, where `refundProgress` counted bidders and `totalBids` counted units, so the condition never held and 11,539.5 ETH stayed locked. Other breaks: last-second bids with no extension (sniping; SOL-AM-FrA-1), extension without a cap (infinite auction), bid increments of 1 wei, reserve price bypassed by a zero first bid, seller cancelling after bids, settle callable before end, Dutch auction price computed with underflow after `endTime`.
- Where: `bid`, `settle`, `withdraw`, `processRefunds`, `claimProceeds`, counters that mix units and participants (SOL-Heuristics-16).
- Question: can any participant make settlement or another bidder's refund revert, and does every counter in a completion condition use the same unit?
- Prove: bidder contract reverting on receive; fuzz bid sequences; assert settlement succeeds and Σ refundable = Σ losing bids.

### Mint allowlists, signatures and caps
- Mechanism: mint signatures not bound to `msg.sender`, quantity, phase and contract, or without a nonce/used flag. NBA "The Association" (Apr 2022): the allowlist signature was not tied to the minter, so others reused valid signatures. Merkle allowlists whose leaf omits the address or allocation, or uses 64-byte leaves (second-preimage, SOL-HMT-5); per-wallet limits counted by `balanceOf` (transfer away and mint again) or bypassed by many contracts/accounts (SOL-AM-SybilAttack-1); `tx.origin == msg.sender` "no contracts" checks (`skill://smart-contract-audit/references/account-abstraction.md`); `_mint` to contracts that cannot handle NFTs (SOL-Token-NfE1-1); refunds of overpayment missing.
- Where: `mint`, `allowlistMint`, `claim`, `MerkleProof.verify` leaf construction, `numberMinted` accounting, ERC721A `_mint(to, quantity)` with `quantity` unbounded.
- Question: for each mint path, what binds an authorization to one minter and one allocation, and what cap counter cannot be reset by transferring?
- Prove: reuse one signature from a second account; mint, transfer, mint again; mint across phases; assert caps hold.

### Reveal and rarity randomness
- Mechanism: metadata assignment derived from `block.timestamp`, `blockhash` or `prevrandao` is predictable or influenceable (SOL-AM-MA-2); a reveal seed set by the owner after mint lets the team pick rare ids; minters see revealed metadata before minting closes and mint only rares (revert-on-bad-outcome); VRF requests whose fulfilment can be frontrun or reorged (SOL-Integrations-Chainlink-VRF-3, SOL-Integrations-Chainlink-VRF-4).
- Where: `reveal`, `setBaseURI` after mint, `fulfillRandomWords`, `tokenURI` offset math (`(id + offset) % maxSupply`).
- Question: who can know or influence the id → metadata mapping before the last mint, and can a minter revert an unwanted outcome?
- Prove: test that mints, computes the outcome in the same transaction, and reverts on non-rare.

### ERC721A and enumerable implementations
- Mechanism: ERC721A packs ownership (`address` in bits 0–159, start timestamp 160–223, burned bit 224, next-initialized bit 225, extra data 232–255) and initializes it lazily: `ownerOf` scans back to the nearest initialized slot. Overrides that write `_packedOwnerships` directly, assume `_startTokenId() == 0` or change it after minting, or read ownership inside hooks before initialization break ownership. Hooks `_beforeTokenTransfers`/`_afterTokenTransfers` receive `(from, to, startTokenId, quantity)`; logic that assumes one token per call miscounts batches. `tokensOfOwner` scans the id range and is meant for off-chain calls; on-chain use is a gas DoS (SOL-Basics-AL-9). OZ `ERC721Consecutive` has its own advisory (SOL-Basics-VI-OVI-8).
- Question: does custom code read or write ownership only through the library's accessors, and do hooks handle `quantity > 1`?
- Prove: mint a batch, transfer a middle id, burn neighbors; assert `ownerOf` for every id matches a reference mapping.

### NFT-backed lending and floor-price liquidation
- Mechanism: collateral valued by a floor price that collapses or is manipulable through thin-market wash trades (SOL-Defi-Oracle-13, SOL-Defi-Oracle-14); liquidation auctions that require bids near the stale floor attract none. BendDAO (Aug 2022): liquidation bids had to exceed 95% of the floor and the debt with a 48-hour auction; as floors fell, nobody bid, lenders ran, and WETH reserves fell from about 18,000 to under 15 until governance lowered the bid floor and auction time.
- Where: oracle source and update cadence, `liquidate`/`auction` parameters, health factor with per-collection LTV, repay-during-auction paths, flash-loan claims of airdrops for escrowed NFTs (SOL-Token-NfE1-7).
- Question: in a 50% floor drop over the auction duration, does any rational bidder exist at the required bid, and what bad debt results if none does?
- Prove: fork test with a shocked oracle and no bidders; property: invariant 10 under oracle shocks; walk `skill://smart-contract-audit/references/playbooks/lending.md`.

### Fractionalization and buyouts
- Mechanism: fraction tokens are ERC-20 vault shares over one indivisible asset. Buyout auctions priced from fraction trades are manipulable; a buyout that completes while fractions sit in AMMs or lending pools leaves those holders unpaid if redemption requires an action they cannot take; reserve price set by a whale; first-depositor share inflation on pooled NFT vaults (walk `skill://smart-contract-audit/references/playbooks/vaults.md`).
- Where: `startBuyout`, `bid`, `redeem`, `cash`, `reservePrice` updates weighted by holdings, NFT AMM bonding-curve `spotPrice`/`delta` updates and their rounding direction (SOL-Basics-Math-5).
- Question: after a buyout, can every fraction holder redeem their pro-rata proceeds without anyone else's cooperation, and can one holder set the reserve after acquiring a temporary majority?
- Prove: property: invariant 11; flash-acquire fractions → vote reserve → buy out in one transaction.

## Checklist items to walk

- NFT tokens: SOL-Token-NfE1-1, SOL-Token-NfE1-2, SOL-Token-NfE1-3, SOL-Token-NfE1-4, SOL-Token-NfE1-5, SOL-Token-NfE1-6, SOL-Token-NfE1-7, SOL-Token-NfE1-8, SOL-Basics-VI-OVI-8, SOL-Basics-VI-OVI-16
- Signatures and merkle: SOL-Signature-1, SOL-Signature-2, SOL-Signature-3, SOL-Signature-4, SOL-Signature-5, SOL-HMT-1, SOL-HMT-2, SOL-HMT-3, SOL-HMT-4, SOL-HMT-5, SOL-Basics-VI-OVI-3, SOL-Basics-VI-OVI-5, SOL-Basics-VI-OVI-12, SOL-Basics-VI-SVI-4, SOL-AM-ReplayAttack-1, SOL-AM-ReplayAttack-2
- Payments: SOL-Basics-Payment-1, SOL-Basics-Payment-2, SOL-Basics-Payment-3, SOL-Basics-Payment-4, SOL-Basics-Payment-5, SOL-Basics-Payment-6, SOL-Basics-Payment-7, SOL-Token-FE-14; weird-erc20 A1, A4, B1, C1, D4, D5, E1 in `skill://smart-contract-audit/references/weird-erc20.md`
- DoS and auctions: SOL-AM-DOSA-1, SOL-AM-DOSA-3, SOL-AM-DOSA-4, SOL-AM-DOSA-6, SOL-AM-FrA-1, SOL-AM-FrA-4, SOL-AM-GA-1, SOL-Basics-AL-9, SOL-Basics-AL-10
- Reentrancy and calls: SOL-AM-ReentrancyAttack-1, SOL-AM-ReentrancyAttack-2, SOL-Defi-LSD-3, SOL-EC-7, SOL-EC-9, SOL-EC-14
- Randomness: SOL-AM-MA-2, SOL-Integrations-Chainlink-VRF-1, SOL-Integrations-Chainlink-VRF-2, SOL-Integrations-Chainlink-VRF-3, SOL-Integrations-Chainlink-VRF-4
- Math and heuristics: SOL-Basics-Math-2, SOL-Basics-Math-5, SOL-Heuristics-3, SOL-Heuristics-12, SOL-Heuristics-16, SOL-AM-SybilAttack-1
- NFT finance: SOL-Defi-Oracle-13, SOL-Defi-Oracle-14, SOL-Defi-Lending-1, SOL-Defi-FlashLoan-1
- Admin: SOL-CR-2, SOL-CR-4, SOL-CR-7
- Whole categories: `skill://smart-contract-audit/references/arbitrary-calls-approvals.md`, `skill://smart-contract-audit/references/account-abstraction.md`, `skill://smart-contract-audit/references/upgradeability.md`

PoC shapes: `skill://test-foundry/references/exploit-poc.md`. Order, payment and auction properties: `skill://fuzz-echidna-medusa/references/property-catalog.md`. Rate findings with `skill://smart-contract-audit/references/methodology/severity.md`.

## Precedent

- OpenSea stale listings, 2022: old signed listings filled after NFTs returned to the seller's wallet. https://www.theverge.com/2022/1/24/22899125/opensea-bug-bored-ape-nfts-smart-contract-listings-cancellation
- OpenSea/Wyvern phishing, 2022: phished Wyvern order signatures filled against existing approvals; 254 NFTs taken. https://www.theverge.com/2022/2/20/22943228/opensea-phishing-hack-smart-contract-bug-stolen-nft
- TreasureDAO marketplace, 2022: `_quantity = 0` priced an ERC-721 purchase at zero. https://slowmist.medium.com/analysis-of-the-treasuredao-zero-fee-exploit-73791f4b9c14
- Revest Finance, 2022: ERC-1155 receive-hook reentrancy into an unchecked deposit path. https://blocksec.com/blog/revest-finance-vulnerabilities-more-than-re-entrancy
- NBA "The Association", 2022: allowlist mint signature not bound to the minter, reused by others. https://blocksec.com/blog/how-to-verify-a-signature-in-a-wrong-way-the-association-nft-case-1
- Akutar, 2022: unit/participant counter mismatch locked 11,539.5 ETH; push-refund loop griefable. https://github.com/calvwang9/akutars-auction-post-mortem
- Omni Protocol, 2022: `onERC721Received` reentrancy during collateral withdrawal and liquidation. https://immunefi.com/blog/bug-fix-reviews/hack-analysis-omni-protocol-july-2022/
- BendDAO, 2022: 95%-of-floor bid requirement and 48h auctions left liquidations unbid during a floor drop; bank run. https://www.bankless.com/the-benddao-bank-run-
- Seaport documentation (reference, not incident): counters, criteria items, zones, bulk orders. https://github.com/ProjectOpenSea/seaport/blob/main/docs/SeaportDocumentation.md
- ERC-2981 (reference): royalty payment is voluntary and unbounded by the standard. https://eips.ethereum.org/EIPS/eip-2981
