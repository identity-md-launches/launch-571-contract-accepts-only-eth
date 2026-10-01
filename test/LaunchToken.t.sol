// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "OneEthCap");
        assertEq(token.symbol(), "ONECAP");
        assertEq(token.decimals(), 18);
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferMovesExactAmount() public {
        vm.expectEmit(true, true, false, true);
        emit LaunchToken.Transfer(deployer, alice, 1234);
        assertTrue(token.transfer(alice, 1234));
        assertEq(token.balanceOf(alice), 1234);
        assertEq(token.balanceOf(deployer), SUPPLY - 1234);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        assertTrue(token.approve(alice, 500));
        assertEq(token.allowance(deployer, alice), 500);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 300));
        assertEq(token.balanceOf(bob), 300);
        assertEq(token.allowance(deployer, alice), 200);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, 200, 201));
        token.transferFrom(deployer, bob, 201);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_noMintOrAdminSurface() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
    }
}
