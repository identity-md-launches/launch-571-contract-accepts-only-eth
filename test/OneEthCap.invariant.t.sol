// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OneEthCap} from "src/OneEthCap.sol";

contract CapSweepReceiver {
    bool public rejecting;

    function setRejecting(bool value) external {
        rejecting = value;
    }

    receive() external payable {
        require(!rejecting, "receiver rejects ETH");
    }
}

/// @dev Exercise forced ETH through an actual EVM transfer, without editing the cap's balance.
contract CapForcedTransfer {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev Handler that drives deposits and sweeps with bounded random inputs and keeps a ghost ledger.
contract CapHandler is Test {
    uint256 internal constant LIMIT = 1 ether;
    uint256 public constant ACTOR_FUNDS = 1_000 ether;
    OneEthCap public immutable cap;
    CapSweepReceiver public immutable receiver;
    address[3] public actors;
    uint256[3] public actorDeposits;
    uint256 public ghostAccepted;
    uint256 public ghostSwept;
    uint256 public ghostForced;
    uint256 public acceptedCalls;
    uint256 public rejectedCalls;
    uint256 public successfulSweeps;
    uint256 public rejectedSweeps;

    constructor(OneEthCap cap_, CapSweepReceiver receiver_) {
        cap = cap_;
        receiver = receiver_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("cap-actor-", vm.toString(i)));
            vm.deal(actors[i], ACTOR_FUNDS);
        }
    }

    function depositVia(uint256 actorSeed, uint256 amount, bool viaReceive) external {
        _deposit(actorSeed % actors.length, bound(amount, 0, 2 ether), viaReceive);
    }

    /// @dev Reach valid small deposits and the exact remaining amount even late in a sequence.
    function depositWithinRoom(uint256 actorSeed, uint256 amountSeed, bool viaReceive) external {
        uint256 room = LIMIT - ghostAccepted;
        uint256 amount = room == 0 ? 1 : bound(amountSeed, 1, room);
        _deposit(actorSeed % actors.length, amount, viaReceive);
    }

    function depositAboveRoom(uint256 actorSeed, uint256 excess, bool viaReceive) external {
        uint256 amount = LIMIT - ghostAccepted + bound(excess, 1, 1 ether);
        _deposit(actorSeed % actors.length, amount, viaReceive);
    }

    function _deposit(uint256 actorIndex, uint256 amount, bool viaReceive) internal {
        address actor = actors[actorIndex];
        uint256 senderBefore = actor.balance;
        uint256 balanceBefore = address(cap).balance;
        uint256 receiverBefore = address(receiver).balance;
        uint256 room = LIMIT - ghostAccepted;
        bytes memory data = viaReceive ? bytes("") : abi.encodeCall(OneEthCap.deposit, ());

        vm.prank(actor);
        (bool ok, bytes memory result) = address(cap).call{value: amount}(data);
        if (amount == 0 || amount > room) {
            assertFalse(ok, "invalid deposit succeeded");
            bytes memory expected = amount == 0
                ? abi.encodeWithSelector(OneEthCap.ZeroValue.selector)
                : abi.encodeWithSelector(OneEthCap.CapExceeded.selector, room, amount);
            assertEq(result, expected, "wrong deposit error");
            assertEq(actor.balance, senderBefore, "failed deposit charged sender");
            assertEq(address(cap).balance, balanceBefore, "failed deposit kept ETH");
            rejectedCalls++;
        } else {
            assertTrue(ok, "valid deposit rejected");
            assertEq(actor.balance, senderBefore - amount, "incorrect deposit cost");
            assertEq(address(cap).balance, balanceBefore + amount, "missing deposit ETH");
            ghostAccepted += amount;
            actorDeposits[actorIndex] += amount;
            acceptedCalls++;
        }
        assertEq(address(receiver).balance, receiverBefore, "deposit paid beneficiary early");
        _assertCounters();
    }

    function rejectCalldata(uint256 actorSeed, uint256 amount, bytes32 suffix) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0, 2 ether);
        uint256 senderBefore = actor.balance;
        uint256 balanceBefore = address(cap).balance;
        uint256 receiverBefore = address(receiver).balance;
        vm.prank(actor);
        (bool ok, bytes memory result) = address(cap).call{value: amount}(abi.encodePacked(hex"deadbeef", suffix));
        assertFalse(ok, "unknown selector accepted");
        assertEq(result, abi.encodeWithSelector(OneEthCap.OnlyEth.selector));
        assertEq(actor.balance, senderBefore, "fallback charged sender");
        assertEq(address(cap).balance, balanceBefore, "fallback kept ETH");
        assertEq(address(receiver).balance, receiverBefore);
        _assertCounters();
    }

    function sweep(uint256 actorSeed, bool rejecting) external {
        receiver.setRejecting(rejecting);
        address actor = actors[actorSeed % actors.length];
        uint256 senderBefore = actor.balance;
        uint256 balanceBefore = address(cap).balance;
        uint256 receiverBefore = address(receiver).balance;
        vm.prank(actor);
        (bool ok, bytes memory result) = address(cap).call(abi.encodeCall(OneEthCap.sweep, ()));

        if (balanceBefore == 0 || rejecting) {
            assertFalse(ok, "invalid sweep succeeded");
            assertEq(
                result,
                abi.encodeWithSelector(
                    balanceBefore == 0 ? OneEthCap.NothingToSweep.selector : OneEthCap.SweepFailed.selector
                ),
                "wrong sweep error"
            );
            assertEq(address(cap).balance, balanceBefore, "failed sweep lost ETH");
            assertEq(address(receiver).balance, receiverBefore, "failed sweep paid receiver");
            rejectedSweeps++;
        } else {
            assertTrue(ok, "funded sweep to willing receiver failed");
            assertEq(address(cap).balance, 0, "sweep left ETH behind");
            assertEq(address(receiver).balance, receiverBefore + balanceBefore, "incorrect payout");
            ghostSwept += balanceBefore;
            successfulSweeps++;
        }
        assertEq(actor.balance, senderBefore, "sweep paid its caller");
        _assertCounters();
    }

    function forceEth(uint256 amount) external {
        amount = bound(amount, 1, 2 ether);
        vm.deal(address(this), amount);
        uint256 balanceBefore = address(cap).balance;
        uint256 receiverBefore = address(receiver).balance;
        new CapForcedTransfer{value: amount}(payable(address(cap)));
        ghostForced += amount;
        assertEq(address(cap).balance, balanceBefore + amount, "forced transfer missed target");
        assertEq(address(receiver).balance, receiverBefore);
        _assertCounters();
    }

    function _assertCounters() internal view {
        assertEq(cap.totalAccepted(), ghostAccepted, "accepted ledger mismatch");
        assertEq(cap.totalSwept(), ghostSwept, "swept ledger mismatch");
    }
}

/// @dev Expected target reverts are caught and checked; any handler revert must fail the run.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract OneEthCapInvariantTest is Test {
    OneEthCap internal cap;
    CapHandler internal handler;
    CapSweepReceiver internal beneficiary;

    function setUp() public {
        beneficiary = new CapSweepReceiver();
        cap = new OneEthCap(address(beneficiary));
        handler = new CapHandler(cap, beneficiary);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = CapHandler.depositVia.selector;
        selectors[1] = CapHandler.depositWithinRoom.selector;
        selectors[2] = CapHandler.depositAboveRoom.selector;
        selectors[3] = CapHandler.rejectCalldata.selector;
        selectors[4] = CapHandler.sweep.selector;
        selectors[5] = CapHandler.forceEth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_totalAcceptedNeverExceedsCap() public view {
        assertEq(cap.CAP(), 1 ether);
        assertLe(cap.totalAccepted(), 1 ether);
        assertEq(cap.remaining() + cap.totalAccepted(), 1 ether);
        assertEq(cap.beneficiary(), address(beneficiary));
    }

    function invariant_ledgerMatchesGhost() public view {
        assertEq(cap.totalAccepted(), handler.ghostAccepted());
        assertEq(cap.totalSwept(), handler.ghostSwept());
    }

    function invariant_fundsAreConserved() public view {
        // Forced ETH bypasses receive(); only voluntary deposits consume the lifetime cap.
        assertEq(address(cap).balance + address(beneficiary).balance, handler.ghostAccepted() + handler.ghostForced());
        assertEq(address(beneficiary).balance, cap.totalSwept());
    }

    function invariant_onlyDepositorsPayAndOnlyBeneficiaryReceives() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 deposited = handler.actorDeposits(i);
            sum += deposited;
            assertEq(handler.actors(i).balance + deposited, handler.ACTOR_FUNDS());
        }
        assertEq(sum, handler.ghostAccepted());
    }

    /// @dev Pin a sequence that reaches every action, both deposit routes and sweep outcomes.
    function test_handlerExercisesFundingRejectionAndLifetimeClosure() public {
        handler.sweep(0, false);
        handler.depositVia(0, 0, false);
        handler.depositVia(0, 0.4 ether, false);
        handler.depositAboveRoom(1, 1, true);
        handler.rejectCalldata(2, 1, bytes32(0));
        handler.sweep(1, true);
        handler.forceEth(2 ether);
        handler.sweep(2, false);
        handler.depositWithinRoom(1, 0.6 ether, true);
        handler.sweep(0, false);
        handler.depositWithinRoom(2, 1, false);

        assertEq(handler.acceptedCalls(), 2);
        assertEq(handler.rejectedCalls(), 3);
        assertEq(handler.successfulSweeps(), 2);
        assertEq(handler.rejectedSweeps(), 2);
        assertEq(cap.remaining(), 0);
        assertEq(address(beneficiary).balance, 3 ether);
        invariant_totalAcceptedNeverExceedsCap();
        invariant_ledgerMatchesGhost();
        invariant_fundsAreConserved();
        invariant_onlyDepositorsPayAndOnlyBeneficiaryReceives();
    }
}
