// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IERC20
/// @notice Minimal ERC20 interface used by {CrowdFund} to escrow token contributions.
/// @dev    Only the methods the protocol actually calls are declared. Return values are
///         intentionally typed as `bool`, but {CrowdFund} tolerates non-compliant tokens
///         that return no data via low-level calls.
interface IERC20 {
    /// @notice Move `amount` tokens from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Move `amount` tokens from `from` to `to` using the caller's allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Token balance of `account`.
    function balanceOf(address account) external view returns (uint256);
}
