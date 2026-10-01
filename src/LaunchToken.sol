// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LaunchToken
/// @notice Fixed-supply ERC-20 for the project launch. The whole supply is minted once, to the
/// deployer, in the constructor. There is no owner, no mint, no burn, no pause, no blocklist,
/// no fee and no upgrade path: transfers move exactly the amount asked, forever.
/// @dev Self-contained so the launch does not depend on any vendored token library. Follows
/// EIP-20 exactly, including the `Approval` event on `transferFrom` spending (an OpenZeppelin v5
/// convention is to skip it; emitting it is harmless and more observable).
contract LaunchToken {
    string public constant name = "OneEthCap";
    string public constant symbol = "ONECAP";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 tokens in 18-decimal minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(uint256 available, uint256 requested);
    error InsufficientAllowance(uint256 available, uint256 requested);
    error ZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(allowed, amount);
            uint256 remaining;
            unchecked {
                remaining = allowed - amount;
            }
            allowance[from][msg.sender] = remaining;
            emit Approval(from, msg.sender, remaining);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            // Supply is fixed at 1e27, so no balance can overflow a uint256.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
