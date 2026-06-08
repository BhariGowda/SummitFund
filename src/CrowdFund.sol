// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";

/// @title CrowdFund
/// @author crowdfund-dapp
/// @notice A single, self-contained crowdfunding campaign. Funds are escrowed by
///         this contract until the deadline. If the funding goal is reached the
///         creator may withdraw the full balance; otherwise contributors may
///         reclaim their individual contributions.
/// @dev    One deployed instance represents exactly one campaign. Instances are
///         intended to be produced by {CrowdFundFactory} via CREATE2, but the
///         contract is fully usable on its own.
///
///         A campaign denominates its funds in either native ETH or a single ERC20
///         token, fixed at construction. When {token} is the zero address the campaign
///         is in ETH mode and contributions arrive as `msg.value`; otherwise it is in
///         ERC20 mode and contributions are pulled with `transferFrom`. The goal,
///         `totalRaised`, and `contributions` are all denominated in the campaign's
///         unit (wei for ETH, base units for the token).
contract CrowdFund {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a non-creator calls a creator-only function.
    error NotCreator();
    /// @notice Thrown when the constructor receives a zero address creator.
    error ZeroCreator();
    /// @notice Thrown when the funding goal is zero.
    error ZeroGoal();
    /// @notice Thrown when the deadline is not strictly in the future at deploy time.
    error DeadlineInPast();
    /// @notice Thrown when contributing after the deadline has passed.
    error CampaignEnded();
    /// @notice Thrown when a contribution carries zero value.
    error ZeroContribution();
    /// @notice Thrown when withdrawing before the goal has been reached.
    error GoalNotReached();
    /// @notice Thrown when the creator tries to withdraw more than once.
    error AlreadyWithdrawn();
    /// @notice Thrown when refunding before the deadline has passed.
    error CampaignNotEnded();
    /// @notice Thrown when refunding a campaign whose goal was reached.
    error GoalReached();
    /// @notice Thrown when an address with no contribution requests a refund.
    error NothingToRefund();
    /// @notice Thrown when the low-level ETH transfer fails.
    error TransferFailed();
    /// @notice Thrown when an ERC20 transfer or transferFrom fails.
    error TokenTransferFailed();
    /// @notice Thrown when a campaign is constructed with a non-zero token address that
    ///         holds no contract code, i.e. an EOA or undeployed account.
    error InvalidToken();
    /// @notice Thrown when an ERC20-only path is given the zero token address, which would
    ///         silently fall back to ETH mode. Used by the factory's ERC20 entrypoint.
    error TokenNotSupported();
    /// @notice Thrown when the ETH `contribute()` entrypoint is used on a token campaign.
    error NotEthCampaign();
    /// @notice Thrown when the ERC20 `contribute(uint256)` entrypoint is used on an ETH
    ///         campaign, or when ETH is sent to a token campaign.
    error NotTokenCampaign();
    /// @notice Thrown when a function guarded against reentrancy is re-entered.
    error Reentrancy();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once at construction with the campaign's immutable terms.
    /// @param creator  Address entitled to withdraw funds on success.
    /// @param title    Human-readable campaign title.
    /// @param goal     Funding target in the campaign's unit.
    /// @param deadline Unix timestamp after which contributions are closed.
    event CampaignCreated(address indexed creator, string title, uint256 goal, uint256 deadline);

    /// @notice Emitted on every successful contribution.
    /// @param contributor   Address that sent the funds.
    /// @param amount        Amount contributed in this call (campaign unit).
    /// @param totalRaised   Running total raised by the campaign after this call.
    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);

    /// @notice Emitted when the creator withdraws the raised funds on success.
    /// @param creator Address that received the funds.
    /// @param amount  Total amount withdrawn (campaign unit).
    event Withdrawn(address indexed creator, uint256 amount);

    /// @notice Emitted when a contributor reclaims funds on failure.
    /// @param contributor Address that received the refund.
    /// @param amount      Amount refunded (campaign unit).
    event Refunded(address indexed contributor, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The address allowed to withdraw funds if the goal is met.
    address public immutable creator;

    /// @notice The ERC20 token funds are denominated in, or `address(0)` for native ETH.
    address public immutable token;

    /// @notice The funding target in the campaign's unit. Reaching or exceeding it marks success.
    uint256 public immutable goal;

    /// @notice Unix timestamp after which contributions are rejected.
    uint256 public immutable deadline;

    /// @notice Human-readable campaign title.
    string public title;

    /// @notice Total amount contributed across all contributors (campaign unit).
    uint256 public totalRaised;

    /// @notice True once the creator has withdrawn the funds. Prevents double withdrawal.
    bool public withdrawn;

    /// @notice Per-contributor contributed amount, used to compute refunds.
    mapping(address => uint256) public contributions;

    /// @dev Reentrancy guard state. 1 = unlocked, 2 = locked. Cheaper than a bool flip
    ///      pattern across calls and avoids the zero->nonzero refund quirk.
    uint256 private _locked = 1;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Blocks reentrancy on the value-moving entrypoints. Necessary because ERC20
    ///      campaigns make external token calls and some tokens hand control to callers.
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a campaign with fixed terms.
    /// @param _creator  Address entitled to withdraw on success. Must be non-zero.
    /// @param _token    ERC20 token to denominate the campaign in, or `address(0)` for ETH.
    /// @param _title    Human-readable title.
    /// @param _goal     Funding target in the campaign's unit. Must be non-zero.
    /// @param _deadline Unix timestamp strictly in the future.
    constructor(address _creator, address _token, string memory _title, uint256 _goal, uint256 _deadline) {
        if (_creator == address(0)) revert ZeroCreator();
        if (_goal == 0) revert ZeroGoal();
        if (_deadline <= block.timestamp) revert DeadlineInPast();
        // A non-zero token must be a real contract; an EOA here would brick contribute().
        if (_token != address(0) && _token.code.length == 0) revert InvalidToken();

        creator = _creator;
        token = _token;
        title = _title;
        goal = _goal;
        deadline = _deadline;

        emit CampaignCreated(_creator, _title, _goal, _deadline);
    }

    /*//////////////////////////////////////////////////////////////
                            MUTATIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Contribute ETH to an ETH-denominated campaign before the deadline.
    /// @dev    Reverts on a token campaign, after the deadline, or on zero value. Updates
    ///         the caller's tracked contribution so they remain eligible for a refund on
    ///         failure.
    function contribute() external payable nonReentrant {
        if (token != address(0)) revert NotEthCampaign();
        if (block.timestamp > deadline) revert CampaignEnded();
        if (msg.value == 0) revert ZeroContribution();

        _record(msg.sender, msg.value);
    }

    /// @notice Contribute ERC20 tokens to a token-denominated campaign before the deadline.
    /// @dev    Pulls `amount` tokens from the caller via `transferFrom`; the caller must
    ///         have approved this contract first. The amount actually credited is measured
    ///         by the contract's balance delta, so fee-on-transfer tokens are accounted for
    ///         correctly. Reverts on an ETH campaign, after the deadline, or on zero value.
    /// @param amount The number of token base units to contribute.
    function contribute(uint256 amount) external nonReentrant {
        if (token == address(0)) revert NotTokenCampaign();
        if (block.timestamp > deadline) revert CampaignEnded();
        if (amount == 0) revert ZeroContribution();

        uint256 before = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroContribution();

        _record(msg.sender, received);
    }

    /// @notice Withdraw the full raised balance to the creator once the goal is met.
    /// @dev    Callable only by the creator and only once. Reaching the goal is a
    ///         success condition that holds even before the deadline, so the creator
    ///         need not wait. Follows checks-effects-interactions and is reentrancy-guarded.
    function withdraw() external nonReentrant {
        if (msg.sender != creator) revert NotCreator();
        if (totalRaised < goal) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        // Effects.
        withdrawn = true;
        uint256 amount = _balance();

        // Interaction.
        emit Withdrawn(creator, amount);
        _payout(creator, amount);
    }

    /// @notice Reclaim your contribution after a failed campaign.
    /// @dev    Only valid once the deadline has passed and the goal was not reached.
    ///         Zeroes the caller's contribution before transferring (CEI) to block
    ///         reentrancy and double-refunds.
    function refund() external nonReentrant {
        if (block.timestamp <= deadline) revert CampaignNotEnded();
        if (totalRaised >= goal) revert GoalReached();

        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToRefund();

        // Effects.
        contributions[msg.sender] = 0;

        // Interaction.
        emit Refunded(msg.sender, amount);
        _payout(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether this campaign is denominated in an ERC20 token rather than ETH.
    /// @return True if a token address was set at construction.
    function isERC20() external view returns (bool) {
        return token != address(0);
    }

    /// @notice Whether the funding goal has been reached.
    /// @return True if total raised is greater than or equal to the goal.
    function goalReached() external view returns (bool) {
        return totalRaised >= goal;
    }

    /// @notice Whether the campaign is still accepting contributions.
    /// @return True if the current time is at or before the deadline.
    function isActive() external view returns (bool) {
        return block.timestamp <= deadline;
    }

    /// @notice Seconds remaining until the deadline, or zero if it has passed.
    /// @return The remaining time in seconds.
    function timeRemaining() external view returns (uint256) {
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Records a credited contribution and emits {Contributed}. No external calls.
    function _record(address contributor, uint256 amount) private {
        contributions[contributor] += amount;
        uint256 raised = totalRaised + amount;
        totalRaised = raised;

        emit Contributed(contributor, amount, raised);
    }

    /// @dev The escrowed balance in the campaign's unit (ETH balance or token balance).
    function _balance() private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @dev Pays `amount` of the campaign's unit out to `to`, picking ETH or ERC20.
    function _payout(address to, uint256 amount) private {
        if (token == address(0)) {
            _safeTransfer(to, amount);
        } else {
            _safeTransferToken(to, amount);
        }
    }

    /// @dev Forwards all gas and bubbles up failure as {TransferFailed}.
    /// @param to     Recipient of the ETH.
    /// @param amount Amount to send in wei.
    function _safeTransfer(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev ERC20 `transfer` that tolerates non-compliant tokens which return no data.
    ///      Reverts as {TokenTransferFailed} on a failed call or an explicit `false`.
    function _safeTransferToken(address to, uint256 amount) private {
        _callToken(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    }

    /// @dev ERC20 `transferFrom` that tolerates non-compliant tokens which return no data.
    ///      Reverts as {TokenTransferFailed} on a failed call or an explicit `false`.
    function _safeTransferFrom(address from, address to, uint256 amount) private {
        _callToken(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    }

    /// @dev Performs a low-level call to {token} and validates the optional boolean return,
    ///      matching the de-facto SafeERC20 semantics used across the ecosystem.
    function _callToken(bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
    }
}
