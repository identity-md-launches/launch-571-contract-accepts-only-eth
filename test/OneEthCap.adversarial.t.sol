// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OneEthCap} from "src/OneEthCap.sol";

/// @dev Exercises a beneficiary that returns some ETH before optionally sweeping it again.
contract RedepositingBeneficiary {
    OneEthCap public cap;
    uint256 public redeposit;
    uint256 public callbacks;
    uint256 public acceptedAtCallback;
    uint256 public sweptAtCallback;
    uint256 public capBalanceAtCallback;
    bool public sweepAgain;
    bool public rejectAfterCallback;

    error CallbackRejected();

    function configure(OneEthCap target, uint256 amount, bool nestedSweep, bool reject) external {
        cap = target;
        redeposit = amount;
        sweepAgain = nestedSweep;
        rejectAfterCallback = reject;
    }

    receive() external payable {
        ++callbacks;
        if (callbacks == 1) {
            acceptedAtCallback = cap.totalAccepted();
            sweptAtCallback = cap.totalSwept();
            capBalanceAtCallback = address(cap).balance;
            cap.deposit{value: redeposit}();
            if (sweepAgain) cap.sweep();
            if (rejectAfterCallback) revert CallbackRejected();
        }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract OneEthCapAdversarialTest is Test {
    uint256 internal constant LIMIT = 1 ether;
    OneEthCap internal cap;
    address internal beneficiary = makeAddr("adversarial beneficiary");
    address internal depositor = makeAddr("adversarial depositor");
    address internal sweeper = makeAddr("adversarial sweeper");

    function setUp() public {
        cap = new OneEthCap(beneficiary);
        vm.deal(depositor, 10 ether);
        vm.deal(sweeper, 10 ether);
    }

    function test_maximumValueIsRejectedWithoutArithmeticPanic() public {
        uint256 maximum = type(uint256).max;
        vm.deal(depositor, maximum);
        bytes memory expected = abi.encodeWithSelector(OneEthCap.CapExceeded.selector, LIMIT, maximum);

        vm.prank(depositor);
        (bool ok, bytes memory result) = address(cap).call{value: maximum}("");
        assertFalse(ok);
        assertEq(result, expected);
        vm.prank(depositor);
        vm.expectRevert(expected);
        cap.deposit{value: maximum}();

        assertEq(depositor.balance, maximum);
        assertEq(address(cap).balance, 0);
        assertEq(cap.totalAccepted(), 0);
        assertEq(cap.totalSwept(), 0);
        assertEq(cap.remaining(), LIMIT);
    }

    function test_nonpayableFunctionsRejectEthWithoutChangingState() public {
        vm.prank(depositor);
        cap.deposit{value: 0.4 ether}();

        bytes4[6] memory selectors = [
            bytes4(keccak256("CAP()")),
            bytes4(keccak256("beneficiary()")),
            bytes4(keccak256("totalAccepted()")),
            bytes4(keccak256("totalSwept()")),
            OneEthCap.remaining.selector,
            OneEthCap.sweep.selector
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(sweeper);
            (bool ok,) = address(cap).call{value: 1}(abi.encodeWithSelector(selectors[i]));
            assertFalse(ok, "nonpayable selector accepted value");
            assertEq(sweeper.balance, 10 ether, "failed call retained sender ETH");
            assertEq(beneficiary.balance, 0, "payable sweep reached beneficiary");
            assertEq(address(cap).balance, 0.4 ether);
            assertEq(cap.totalAccepted(), 0.4 ether);
            assertEq(cap.totalSwept(), 0);
            assertEq(cap.remaining(), 0.6 ether);
        }

        // A rejected value-bearing sweep must not prevent an ordinary permissionless sweep.
        vm.prank(sweeper);
        cap.sweep();
        assertEq(beneficiary.balance, 0.4 ether);
        assertEq(sweeper.balance, 10 ether);
        assertEq(cap.totalSwept(), 0.4 ether);
    }

    function testFuzz_shortCalldataRejectsAndRefunds(uint24 payload, uint8 lengthSeed, uint256 value) public {
        uint256 length = bound(lengthSeed, 1, 3);
        value = bound(value, 0, 2 ether);
        bytes memory data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = bytes1(uint8(payload >> (i * 8)));
        }

        vm.prank(depositor);
        cap.deposit{value: 1}();
        uint256 beforeBalance = depositor.balance;
        vm.prank(depositor);
        (bool ok, bytes memory result) = address(cap).call{value: value}(data);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(OneEthCap.OnlyEth.selector));
        assertEq(depositor.balance, beforeBalance);
        assertEq(address(cap).balance, 1);
        assertEq(cap.totalAccepted(), 1);
        assertEq(cap.totalSwept(), 0);
        assertEq(cap.remaining(), LIMIT - 1);
    }

    function testFuzz_receiveOverCapRollsBackAndRemainingCanStillBeFilled(
        uint256 first,
        uint256 excess,
        bool sweepFirst
    ) public {
        first = bound(first, 1, LIMIT - 1);
        excess = bound(excess, 1, LIMIT);
        vm.prank(depositor);
        cap.deposit{value: first}();
        if (sweepFirst) cap.sweep();

        uint256 room = LIMIT - first;
        uint256 attempted = room + excess;
        uint256 beforeBalance = depositor.balance;
        vm.prank(depositor);
        (bool ok, bytes memory result) = address(cap).call{value: attempted}("");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(OneEthCap.CapExceeded.selector, room, attempted));
        assertEq(depositor.balance, beforeBalance);
        assertEq(address(cap).balance, sweepFirst ? 0 : first);
        assertEq(cap.totalAccepted(), first);
        assertEq(cap.totalSwept(), sweepFirst ? first : 0);
        assertEq(cap.remaining(), room);

        vm.prank(depositor);
        (ok,) = address(cap).call{value: room}("");
        assertTrue(ok, "failed receive consumed remaining capacity");
        assertEq(cap.totalAccepted(), LIMIT);
        assertEq(cap.remaining(), 0);
        cap.sweep();
        assertEq(beneficiary.balance, LIMIT);
        assertEq(cap.totalSwept(), LIMIT);
        assertEq(address(cap).balance, 0);
    }

    function testFuzz_callbackRedepositAndNestedSweepConserveFunds(uint256 first, uint256 returned, bool nestedSweep)
        public
    {
        first = bound(first, 1, LIMIT - 1);
        uint256 maximumReturn = first < LIMIT - first ? first : LIMIT - first;
        returned = bound(returned, 1, maximumReturn);
        RedepositingBeneficiary receiver = new RedepositingBeneficiary();
        OneEthCap target = new OneEthCap(address(receiver));
        receiver.configure(target, returned, nestedSweep, false);
        vm.prank(depositor);
        target.deposit{value: first}();

        vm.prank(sweeper);
        target.sweep();
        assertEq(receiver.acceptedAtCallback(), first);
        assertEq(receiver.sweptAtCallback(), first, "sweep accounting must precede the callback");
        assertEq(receiver.capBalanceAtCallback(), 0);
        assertEq(target.totalAccepted(), first + returned);
        assertEq(target.remaining(), LIMIT - first - returned);
        assertEq(target.totalSwept(), nestedSweep ? first + returned : first);
        assertEq(address(target).balance, nestedSweep ? 0 : returned);
        assertEq(address(receiver).balance, nestedSweep ? first : first - returned);
        assertEq(receiver.callbacks(), nestedSweep ? 2 : 1);
        assertEq(address(target).balance + address(receiver).balance, first);
        assertEq(address(target).balance + target.totalSwept(), target.totalAccepted());
        assertEq(sweeper.balance, 10 ether, "permissionless caller received beneficiary funds");

        if (!nestedSweep) target.sweep();
        assertEq(address(receiver).balance, first);
        assertEq(target.totalSwept(), first + returned);
        assertEq(target.totalAccepted(), first + returned);
        assertEq(address(target).balance, 0);
        vm.expectRevert(OneEthCap.NothingToSweep.selector);
        target.sweep();
    }

    function test_revertingBeneficiaryRollsBackNestedDepositAndSweepThenCanRetry() public {
        RedepositingBeneficiary receiver = new RedepositingBeneficiary();
        OneEthCap target = new OneEthCap(address(receiver));
        receiver.configure(target, 0.2 ether, true, true);
        vm.prank(depositor);
        target.deposit{value: 0.4 ether}();

        vm.expectRevert(OneEthCap.SweepFailed.selector);
        target.sweep();
        assertEq(address(target).balance, 0.4 ether);
        assertEq(address(receiver).balance, 0);
        assertEq(target.totalAccepted(), 0.4 ether, "nested deposit was not rolled back");
        assertEq(target.totalSwept(), 0, "outer or nested sweep was not rolled back");
        assertEq(target.remaining(), 0.6 ether);
        assertEq(receiver.callbacks(), 0, "beneficiary state was not rolled back");

        receiver.configure(target, 0.2 ether, true, false);
        target.sweep();
        assertEq(receiver.callbacks(), 2);
        assertEq(address(receiver).balance, 0.4 ether);
        assertEq(address(target).balance, 0);
        assertEq(target.totalAccepted(), 0.6 ether);
        assertEq(target.totalSwept(), 0.6 ether);
        assertEq(target.remaining(), 0.4 ether);
    }

    function test_callbackCannotReopenLifetimeCapDuringSweep() public {
        RedepositingBeneficiary receiver = new RedepositingBeneficiary();
        OneEthCap target = new OneEthCap(address(receiver));
        receiver.configure(target, 1, false, false);
        vm.prank(depositor);
        target.deposit{value: LIMIT}();

        // The receiver propagates the rejected redeposit, so the whole sweep must revert.
        vm.expectRevert(OneEthCap.SweepFailed.selector);
        target.sweep();
        assertEq(target.totalAccepted(), LIMIT);
        assertEq(target.remaining(), 0);
        assertEq(target.totalSwept(), 0);
        assertEq(address(target).balance, LIMIT);
        assertEq(address(receiver).balance, 0);
        assertEq(receiver.callbacks(), 0);
    }
}
