// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OneEthCap} from "../src/OneEthCap.sol";
import {DeployScript} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Minimal ERC-721 whose `safeTransferFrom` performs the standard receiver check.
contract MockNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not owner");
        ownerOf[id] = to;
        if (to.code.length > 0) {
            (bool ok, bytes memory ret) = to.call(
                abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", msg.sender, from, id, "")
            );
            require(
                ok && ret.length == 32
                    && abi.decode(ret, (bytes4))
                        == bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")),
                "unsafe recipient"
            );
        }
    }
}

/// @dev Beneficiary that refuses ETH.
contract RejectingBeneficiary {
    receive() external payable {
        revert("no");
    }
}

/// @dev Beneficiary that tries to re-enter `sweep()` while receiving.
contract ReenteringBeneficiary {
    OneEthCap public cap;
    uint256 public reentryAttempts;
    bool public reentrySucceeded;

    function setCap(OneEthCap cap_) external {
        cap = cap_;
    }

    receive() external payable {
        reentryAttempts++;
        if (reentryAttempts == 1) {
            try cap.sweep() {
                reentrySucceeded = true;
            } catch {}
        }
    }
}

/// @dev Uses SELFDESTRUCT to force ETH into the cap contract without going through receive().
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract OneEthCapTest is Test {
    OneEthCap internal cap;
    address internal beneficiary = makeAddr("beneficiary");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant CAP = 1 ether;

    function setUp() public {
        cap = new OneEthCap(beneficiary);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ------------------------------------------------------------------ construction

    function test_constructorSetsBeneficiary() public view {
        assertEq(cap.beneficiary(), beneficiary);
        assertEq(cap.CAP(), CAP);
        assertEq(cap.totalAccepted(), 0);
        assertEq(cap.remaining(), CAP);
    }

    function test_constructorRejectsZeroBeneficiary() public {
        vm.expectRevert(OneEthCap.ZeroBeneficiary.selector);
        new OneEthCap(address(0));
    }

    function test_deployScriptWiresConstructor() public {
        DeployScript script = new DeployScript();
        (LaunchToken token, OneEthCap deployed) = script.deploy(beneficiary);
        assertEq(deployed.beneficiary(), beneficiary);
        assertEq(token.balanceOf(address(script)), 10 ** 27);
    }

    // ------------------------------------------------------------------ accepting ETH

    function test_receiveAcceptsPlainTransfer() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit OneEthCap.Deposited(alice, 0.4 ether, 0.4 ether);
        (bool ok,) = address(cap).call{value: 0.4 ether}("");
        assertTrue(ok);
        assertEq(cap.totalAccepted(), 0.4 ether);
        assertEq(cap.remaining(), 0.6 ether);
        assertEq(address(cap).balance, 0.4 ether);
    }

    function test_depositAcceptsEth() public {
        vm.prank(bob);
        cap.deposit{value: 0.25 ether}();
        assertEq(cap.totalAccepted(), 0.25 ether);
        assertEq(address(cap).balance, 0.25 ether);
    }

    function test_acceptsExactlyOneEthInOneDeposit() public {
        vm.prank(alice);
        cap.deposit{value: CAP}();
        assertEq(cap.totalAccepted(), CAP);
        assertEq(cap.remaining(), 0);
    }

    function test_acceptsExactlyOneEthAcrossDeposits() public {
        vm.prank(alice);
        cap.deposit{value: 0.7 ether}();
        vm.prank(bob);
        cap.deposit{value: 0.3 ether}();
        assertEq(cap.totalAccepted(), CAP);
        assertEq(address(cap).balance, CAP);
    }

    function test_rejectsSingleDepositOverCap() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OneEthCap.CapExceeded.selector, CAP, CAP + 1));
        cap.deposit{value: CAP + 1}();
        assertEq(cap.totalAccepted(), 0);
        assertEq(address(cap).balance, 0);
    }

    function test_rejectsDepositThatWouldCrossCap() public {
        vm.prank(alice);
        cap.deposit{value: 0.75 ether}();

        // Whole deposit is refused; nothing is partially filled.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OneEthCap.CapExceeded.selector, 0.25 ether, 0.3 ether));
        cap.deposit{value: 0.3 ether}();
        assertEq(cap.totalAccepted(), 0.75 ether);
        assertEq(bob.balance, 10 ether);

        // The remaining room is still open to a deposit that fits.
        vm.prank(bob);
        cap.deposit{value: 0.25 ether}();
        assertEq(cap.totalAccepted(), CAP);
    }

    function test_rejectsEvenOneWeiOnceFull() public {
        vm.prank(alice);
        cap.deposit{value: CAP}();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OneEthCap.CapExceeded.selector, 0, 1));
        cap.deposit{value: 1}();

        vm.prank(bob);
        (bool ok,) = address(cap).call{value: 1}("");
        assertFalse(ok);
    }

    function test_rejectsZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(OneEthCap.ZeroValue.selector);
        cap.deposit();

        vm.prank(alice);
        (bool ok,) = address(cap).call("");
        assertFalse(ok);
    }

    function test_capIsLifetimeNotBalance() public {
        vm.prank(alice);
        cap.deposit{value: CAP}();
        cap.sweep();
        assertEq(address(cap).balance, 0);

        // Room does not reopen after the balance is drained.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OneEthCap.CapExceeded.selector, 0, 1));
        cap.deposit{value: 1}();
        assertEq(cap.remaining(), 0);
    }

    // ------------------------------------------------------------------ only ETH

    function test_fallbackRejectsUnknownCalldata() public {
        vm.prank(alice);
        vm.expectRevert(OneEthCap.OnlyEth.selector);
        (bool ok,) = address(cap).call{value: 0.1 ether}(abi.encodeWithSignature("depositFor(address)", alice));
        ok;

        vm.prank(alice);
        vm.expectRevert(OneEthCap.OnlyEth.selector);
        (ok,) = address(cap).call(hex"deadbeef");
        ok;
        assertEq(cap.totalAccepted(), 0);
    }

    function test_rejectsErc721SafeTransfer() public {
        MockNFT nft = new MockNFT();
        nft.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert("unsafe recipient");
        nft.safeTransferFrom(alice, address(cap), 1);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_rejectsErc1155ReceiverHook() public {
        (bool ok,) = address(cap)
            .call(
                abi.encodeWithSignature(
                    "onERC1155Received(address,address,uint256,uint256,bytes)", alice, alice, 1, 1, ""
                )
            );
        assertFalse(ok);
    }

    function test_rejectsErc777TokensReceivedHook() public {
        (bool ok,) = address(cap)
            .call(
                abi.encodeWithSignature(
                    "tokensReceived(address,address,address,uint256,bytes,bytes)", alice, alice, address(cap), 1, "", ""
                )
            );
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ sweep

    function test_sweepPushesWholeBalanceToBeneficiary() public {
        vm.prank(alice);
        cap.deposit{value: 0.6 ether}();

        vm.prank(bob); // anyone may trigger
        vm.expectEmit(true, false, false, true);
        emit OneEthCap.Swept(beneficiary, 0.6 ether);
        cap.sweep();

        assertEq(beneficiary.balance, 0.6 ether);
        assertEq(address(cap).balance, 0);
        assertEq(cap.totalSwept(), 0.6 ether);
        assertEq(cap.totalAccepted(), 0.6 ether);
    }

    function test_sweepRevertsWhenEmpty() public {
        vm.expectRevert(OneEthCap.NothingToSweep.selector);
        cap.sweep();
    }

    function test_sweepRevertsWhenBeneficiaryRejects() public {
        OneEthCap rejecting = new OneEthCap(address(new RejectingBeneficiary()));
        vm.prank(alice);
        rejecting.deposit{value: 0.1 ether}();

        vm.expectRevert(OneEthCap.SweepFailed.selector);
        rejecting.sweep();
        // State is rolled back with the revert; funds remain in the contract.
        assertEq(address(rejecting).balance, 0.1 ether);
        assertEq(rejecting.totalSwept(), 0);
    }

    function test_sweepReentrancyGainsNothing() public {
        ReenteringBeneficiary reenterer = new ReenteringBeneficiary();
        OneEthCap target = new OneEthCap(address(reenterer));
        reenterer.setCap(target);

        vm.prank(alice);
        target.deposit{value: 0.5 ether}();
        target.sweep();

        assertEq(reenterer.reentryAttempts(), 1);
        assertFalse(reenterer.reentrySucceeded(), "re-entered sweep should find nothing to sweep");
        assertEq(address(reenterer).balance, 0.5 ether);
        assertEq(address(target).balance, 0);
        assertEq(target.totalSwept(), 0.5 ether);
    }

    function test_forcedEthDoesNotCountTowardCapButIsSwept() public {
        new ForceSender{value: 2 ether}(payable(address(cap)));
        assertEq(address(cap).balance, 2 ether);
        assertEq(cap.totalAccepted(), 0, "forced ETH is not accepted ETH");

        // The cap still governs deposits that go through receive()/deposit().
        vm.prank(alice);
        cap.deposit{value: CAP}();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OneEthCap.CapExceeded.selector, 0, 1));
        cap.deposit{value: 1}();

        cap.sweep();
        assertEq(beneficiary.balance, 3 ether);
        assertEq(address(cap).balance, 0);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_totalAcceptedNeverExceedsCap(uint96[8] calldata amounts) public {
        uint256 expected;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = bound(uint256(amounts[i]), 0, 2 ether);
            address sender = i % 2 == 0 ? alice : bob;
            vm.prank(sender);
            (bool ok,) = address(cap).call{value: amount}("");
            bool fits = amount > 0 && expected + amount <= CAP;
            assertEq(ok, fits, "acceptance must match the cap rule exactly");
            if (fits) expected += amount;
        }
        assertEq(cap.totalAccepted(), expected);
        assertLe(cap.totalAccepted(), CAP);
        assertEq(address(cap).balance, expected);
    }

    function testFuzz_depositSucceedsIffItFits(uint256 first, uint256 second) public {
        first = bound(first, 1, CAP);
        second = bound(second, 1, 2 ether);
        vm.prank(alice);
        cap.deposit{value: first}();

        vm.prank(bob);
        if (first + second > CAP) {
            vm.expectRevert(abi.encodeWithSelector(OneEthCap.CapExceeded.selector, CAP - first, second));
            cap.deposit{value: second}();
            assertEq(cap.totalAccepted(), first);
        } else {
            cap.deposit{value: second}();
            assertEq(cap.totalAccepted(), first + second);
        }
    }
}
