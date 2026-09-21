---
name: halmos-verify
description: Prove Solidity properties symbolically with Halmos. Use when the user wants formal verification, a symbolic proof, exhaustive input coverage, check_ tests, halmos.toml bounds, encoder or packing round-trip proofs, or when a solver times out or explodes and the property must be bounded or handed to fuzzing. Triggers on halmos, formal verification, symbolic execution, prove, counterexample, SMT, path explosion.
---

# Halmos proofs

Halmos runs a Foundry test with symbolic inputs and reports a counterexample or an exhaustive pass **within the bounds you set**. The bounds are the whole craft: an unbounded property either explodes or proves less than it appears to.

## What to aim a solver at

Pick targets by shape, not importance.

| Provable and cheap | Hand to fuzzing instead |
| --- | --- |
| encode/decode round trips on bounded shapes | nested container grammars with head/tail aliasing |
| bit packing and unpacking, `packOps`-style layouts | stack machines and interpreters over symbolic programs |
| opcode or selector dispatch tables, every branch | end-to-end multi-contract flows |
| equivalence of two implementations (batch vs packed, public vs internal) | anything looping over symbolic-length data past the `loop` bound |
| access control with a symbolic caller | economic properties needing long call sequences |
| revert-selector correctness on invalid input | properties over accrued time or block progression |

When a target belongs in the right column, record the property as deferred with its reason and cover it with `skill://fuzz-echidna-medusa`. A property matrix — id, statement, status, tool — keeps the deferral visible.

## Setup

```bash
pip install halmos
forge install a16z/halmos-cheatcodes
```

```text
# remappings.txt
halmos-cheatcodes/=lib/halmos-cheatcodes/src/
```

```toml
# halmos.toml
[global]
function = "check"          # symbolic tests are check_*, keeping them out of the forge test suite
loop = 100                  # max loop unrollings
early-exit = false          # keep checking the remaining functions after a counterexample
array-lengths = "toks={3}"  # pin a runaway symbolic array to a concrete length
```

`function = "check"` is what separates the symbolic suite from `test_*`. Keep the config at the repo root and run it from there, so the documented command and the file agree.

```bash
halmos                                     # whole suite under the global config
halmos --contract VaultHalmosTest          # one contract
halmos --match-contract EncoderHalmosTest --loop 100 --array-lengths "toks={3}"
```

## Writing a check

```solidity
import { Test } from "forge-std/Test.sol";
import { SymTest } from "halmos-cheatcodes/SymTest.sol";

contract EncoderHalmosTest is Test, SymTest {
    function check_encode_decode_roundtrip() public {
        bytes32 word = svm.createBytes32("s0");
        uint8 tag = uint8(svm.createUint(8, "t0"));
        bytes4 sel = bytes4(svm.createBytes32("sel"));
        vm.assume(tag < 8);

        bytes memory packed = encoder.pack(tag, sel, word);
        (uint8 tag2, bytes4 sel2, bytes32 word2) = encoder.unpack(packed);

        assertEq(tag2, tag, "tag");
        assertEq(sel2, sel, "selector");
        assertEq(word2, word, "word");
    }
}
```

Four habits decide whether a check is worth its runtime:

- **Label every symbol meaningfully.** The labels (`"s0"`, `"t0"`) are what the counterexample model prints. Unlabeled symbols make a failure unreadable.
- **Constrain the domain with `vm.assume`, then act.** `vm.assume(destCount > 0 && destCount < 27)` states the precondition the contract actually documents. An assumption that hides the bug is the classic false pass, so keep each one traceable to a real constraint.
- **Prove a relation, not a value.** Round trips, equivalence of two code paths, and monotonic relations survive refactors; a hardcoded expected output does not.
- **Bound arrays deliberately.** `array-lengths` in config, or `svm.createBytes(32, "d2")` with a concrete length at the call site.

## Bounding without losing coverage

A symbolic length explodes; a concrete length proves one case. The loop-over-lengths idiom proves every length up to a bound, with the content still symbolic:

```solidity
function check_pack_all_lengths() public {
    uint256 lenSym = svm.createUint(5, "len");   // 0..31
    vm.assume(lenSym < 23);                       // 22 bytes is the packing maximum
    for (uint256 len = 0; len < 23; len++) {
        if (len == lenSym) {
            bytes memory bp = svm.createBytes(len, "bp");
            assertEq(codec.unpack(codec.pack(bp)), bp, "roundtrip");
        }
    }
}
```

Keep every loop over symbolic data below the `loop` bound. A loop that can exceed it reports an unrolling failure, which is a configuration signal and not a finding.

## Reaching internals and reverts

A thin harness exposes `internal` functions, and a low-level call captures the revert so the **selector** can be asserted rather than the mere fact of reverting:

```solidity
contract SafeTransferHarness {
    function executeSafeTransfer(bytes[] memory registers, address token, uint8 toReg, uint8 amountReg) external {
        SafeTransferLib.execute(registers, token, toReg, amountReg);
    }
}

// inside the check
(bool success, bytes memory returnData) = address(h).call(callData);
assertTrue(!success, "should revert");
assertGe(returnData.length, 4, "returnData.length");
assertEq(bytes4(returnData), VmErrors.InvalidAddressBytes.selector, "expected InvalidAddressBytes selector");
```

For token pathologies, one behavior-switching mock covers the matrix in a single symbolic run:

```solidity
token.setBehavior(MinimalERC20.Behavior.FOT);          // also NO_RETURN, FALSE_ON_FAILURE
function check_safeTransfer_all_behaviors(MinimalERC20.Behavior behavior, uint256 amount) public { /* ... */ }
```

## Reading the result

- **Counterexample** — a concrete model per labeled symbol. Transcribe it into a plain `forge test` reproducer, confirm it fails, then treat it exactly like a fuzz trophy: permanent regression test, back-link to the issue.
- **Pass** — exhaustive only inside the bounds and assumptions. State them in the finding: "holds for all inputs with `len < 23` and `loop = 100`". A pass whose bounds are unstated overclaims.
- **Timeout or path explosion** — not a pass and not a finding. Tighten `array-lengths`, lower the symbolic width (`svm.createUint(8, ...)` instead of 256 bits), split the check into cases, or move the property to the fuzzing column and record the deferral.
