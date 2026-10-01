// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OneEthCap} from "../src/OneEthCap.sol";

/// @dev Handler that drives deposits and sweeps with bounded random inputs and keeps a ghost ledger.
contract CapHandler is Test {
    OneEthCap public immutable cap;
    uint256 public ghostAccepted;
    uint256 public ghostSwept;
    uint256 public acceptedCalls;
    uint256 public rejectedCalls;

    constructor(OneEthCap cap_) {
        cap = cap_;
    }

    function depositVia(uint256 amount, bool viaReceive) external {
        amount = bound(amount, 0, 1.5 ether);
        vm.deal(address(this), amount);
        bool ok;
        if (viaReceive) {
            (ok,) = address(cap).call{value: amount}("");
        } else {
            (ok,) = address(cap).call{value: amount}(abi.encodeWithSelector(OneEthCap.deposit.selector));
        }
        if (ok) {
            ghostAccepted += amount;
            acceptedCalls++;
        } else {
            rejectedCalls++;
        }
    }

    function sweep() external {
        uint256 balance = address(cap).balance;
        try cap.sweep() {
            ghostSwept += balance;
        } catch {}
    }
}

contract OneEthCapInvariantTest is Test {
    OneEthCap internal cap;
    CapHandler internal handler;
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        cap = new OneEthCap(beneficiary);
        handler = new CapHandler(cap);
        targetContract(address(handler));
    }

    function invariant_totalAcceptedNeverExceedsCap() public view {
        assertLe(cap.totalAccepted(), cap.CAP());
        assertEq(cap.remaining(), cap.CAP() - cap.totalAccepted());
    }

    function invariant_ledgerMatchesGhost() public view {
        assertEq(cap.totalAccepted(), handler.ghostAccepted());
        assertEq(cap.totalSwept(), handler.ghostSwept());
    }

    function invariant_fundsAreConserved() public view {
        // No forced ETH in this harness, so balance + swept == accepted exactly.
        assertEq(address(cap).balance + cap.totalSwept(), cap.totalAccepted());
        assertEq(beneficiary.balance, cap.totalSwept());
    }
}
