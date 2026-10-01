// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title OneEthCap
/// @notice A contract that accepts only ETH, and never more than 1 ETH in total over its lifetime.
///
/// Behaviour:
///  - ETH is accepted through `receive()` (a plain transfer with empty calldata) or `deposit()`.
///  - Every accepted deposit is added to `totalAccepted`. A deposit that would push
///    `totalAccepted` above `CAP` (1 ether) is rejected in full; partial fills are not performed.
///  - Zero-value deposits are rejected so the counter and events only ever record real ETH.
///  - The cap is lifetime, not a balance cap: sweeping ETH out does not reopen room under it.
///  - Any call carrying calldata that does not match `deposit()` or a view function reverts in
///    `fallback()`. The contract implements no ERC-721, ERC-1155 or ERC-777 receiver hooks, so
///    safe NFT transfers and ERC-777 sends to it revert. Plain ERC-20 `transfer` writes to the
///    token's own storage and cannot be refused by any recipient; such tokens are stuck.
///  - `sweep()` is permissionless and pushes the whole balance to the immutable `beneficiary`.
///    Only the beneficiary ever receives funds, so anyone being able to trigger it is safe.
///
/// What the cap does not cover: ETH forced in by `SELFDESTRUCT` or as a block reward cannot be
/// refused by any contract and does not pass through `receive()`. It is not counted in
/// `totalAccepted`, but `sweep()` forwards it to the beneficiary along with everything else.
contract OneEthCap {
    /// @notice Maximum ETH this contract will ever accept, in wei.
    uint256 public constant CAP = 1 ether;

    /// @notice Address that receives swept ETH. Fixed at deployment.
    address public immutable beneficiary;

    /// @notice Cumulative ETH accepted through `receive()`/`deposit()`. Never decreases.
    uint256 public totalAccepted;

    /// @notice Cumulative ETH pushed to the beneficiary by `sweep()`.
    uint256 public totalSwept;

    event Deposited(address indexed from, uint256 amount, uint256 totalAccepted);
    event Swept(address indexed to, uint256 amount);

    error ZeroBeneficiary();
    error ZeroValue();
    error CapExceeded(uint256 remaining, uint256 requested);
    error OnlyEth();
    error NothingToSweep();
    error SweepFailed();

    /// @param beneficiary_ Recipient of swept ETH. Must be non-zero. Pass `$owner` in the launch
    /// manifest; the factory is `msg.sender` in constructors and must not be used as a recipient.
    constructor(address beneficiary_) {
        if (beneficiary_ == address(0)) revert ZeroBeneficiary();
        beneficiary = beneficiary_;
    }

    /// @notice Accept a plain ETH transfer (empty calldata).
    receive() external payable {
        _accept();
    }

    /// @notice Reject every call that is not a known function or a plain ETH transfer.
    fallback() external payable {
        revert OnlyEth();
    }

    /// @notice Accept ETH explicitly. Identical rules to `receive()`.
    function deposit() external payable {
        _accept();
    }

    /// @notice Wei that can still be accepted before the lifetime cap is reached.
    function remaining() public view returns (uint256) {
        return CAP - totalAccepted;
    }

    /// @notice Push the whole ETH balance to the beneficiary. Anyone may call this.
    function sweep() external {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep();
        totalSwept += amount;
        emit Swept(beneficiary, amount);
        (bool ok,) = beneficiary.call{value: amount}("");
        if (!ok) revert SweepFailed();
    }

    function _accept() private {
        if (msg.value == 0) revert ZeroValue();
        uint256 room = CAP - totalAccepted;
        if (msg.value > room) revert CapExceeded(room, msg.value);
        uint256 newTotal = totalAccepted + msg.value;
        totalAccepted = newTotal;
        emit Deposited(msg.sender, msg.value, newTotal);
    }
}
