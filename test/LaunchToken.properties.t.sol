// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract LaunchTokenPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant ALICE = address(0xA110);
    address internal constant BOB = address(0xB220);
    LaunchToken internal token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_approveZeroAddressReverts() public {
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.approve(address(0), type(uint256).max);
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_zeroTransferNeedsNoBalanceOrAllowance() public {
        vm.startPrank(BOB);
        assertTrue(token.transfer(ALICE, 0));
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_zeroTransferToZeroAddressReverts() public {
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_maximumTransferAmountRevertsWithoutChangingBalances() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, SUPPLY, type(uint256).max));
        token.transfer(ALICE, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_nativeEthAndValueAttachedToTokenCallsRevert() public {
        vm.deal(address(this), 2 ether);
        (bool receiveSuccess,) = address(token).call{value: 1 ether}("");
        assertFalse(receiveSuccess);
        (bool approveSuccess,) = address(token).call{value: 1 ether}(abi.encodeCall(LaunchToken.approve, (ALICE, 1)));
        assertFalse(approveSuccess);
        assertEq(address(token).balance, 0);
        assertEq(address(this).balance, 2 ether);
        assertEq(token.allowance(address(this), ALICE), 0);
    }

    function testFuzz_approvalReplacesPreviousValueAndCanBeRevoked(uint256 first, uint256 replacement) public {
        assertTrue(token.approve(ALICE, first));
        assertEq(token.allowance(address(this), ALICE), first);
        assertTrue(token.approve(ALICE, replacement));
        assertEq(token.allowance(address(this), ALICE), replacement);
        assertTrue(token.approve(ALICE, 0));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, 0, 1));
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(address(this), ALICE), 0);
    }

    function testFuzz_selfTransferPreservesBalance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_delegatedSelfTransferOnlySpendsAllowance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.approve(ALICE, amount);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_failedBalanceCheckRestoresSpentAllowance(uint256 funded, uint256 excess) public {
        funded = bound(funded, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - funded);
        uint256 requested = funded + excess;
        token.transfer(ALICE, funded);
        vm.prank(ALICE);
        token.approve(BOB, requested);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, funded, requested));
        token.transferFrom(ALICE, BOB, requested);
        assertEq(token.allowance(ALICE, BOB), requested);
        assertEq(token.balanceOf(ALICE), funded);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - funded);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_zeroRecipientRestoresSpentAllowance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.approve(ALICE, amount);
        vm.prank(ALICE);
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testFuzz_finiteAllowanceCannotBeSpentTwice(uint256 allowance, uint256 spend) public {
        allowance = bound(allowance, 0, SUPPLY);
        spend = bound(spend, 0, allowance);
        token.approve(ALICE, allowance);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, spend));
        uint256 remaining = allowance - spend;
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, remaining, remaining + 1));
        token.transferFrom(address(this), BOB, remaining + 1);
        assertEq(token.allowance(address(this), ALICE), remaining);
        assertEq(token.balanceOf(address(this)), SUPPLY - spend);
        assertEq(token.balanceOf(BOB), spend);
    }
}

/// @dev The independent ledger starts from the fixed launch allocation; it never reads balances or
/// allowances from the token to decide what a call should do. The fuzzer only targets these actions.
contract LaunchTokenLedgerHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    LaunchToken public immutable token;
    address[4] public actors = [address(0xA110), address(0xB220), address(0xC330), address(0xD440)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        token = new LaunchToken();
        for (uint256 i; i < actors.length; ++i) {
            assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
            expectedBalance[actors[i]] = SUPPLY / actors.length;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = infinite ? type(uint256).max : bound(amount, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner];
        amount = bound(amount, 0, allowed < available ? allowed : available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
    }

    function rejectOverspend(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 available = expectedBalance[from];
        uint256 amount = available + bound(excess, 1, SUPPLY + 1);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, available, amount));
        token.transfer(to, amount);
    }

    function revokeThenRejectSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, 0, 1));
        token.transferFrom(owner, to, 1);
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[owner]);
        vm.prank(owner);
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenLedgerInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    LaunchTokenLedgerHandler internal handler;
    LaunchToken internal token;

    function setUp() public {
        handler = new LaunchTokenLedgerHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.revokeThenRejectSpend.selector;
        selectors[5] = handler.rejectZeroRecipient.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_fixedSupplyIsConservedAndBalancesMatchLedger() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "balance diverged from the ledger");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "transfers created or destroyed tokens");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_allowancesMatchApprovalsAndSuccessfulSpending() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "allowance diverged from successful approvals and spending"
                );
            }
        }
    }
}
