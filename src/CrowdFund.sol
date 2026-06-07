// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title CrowdFund
/// @author crowdfund-dapp
/// @notice A single, self-contained crowdfunding campaign. Funds are escrowed by
///         this contract until the deadline. If the funding goal is reached the
///         creator may withdraw the full balance; otherwise contributors may
///         reclaim their individual contributions.
/// @dev    One deployed instance represents exactly one campaign. Instances are
///         intended to be produced by {CrowdFundFactory} via CREATE2, but the
///         contract is fully usable on its own.
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

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once at construction with the campaign's immutable terms.
    /// @param creator  Address entitled to withdraw funds on success.
    /// @param title    Human-readable campaign title.
    /// @param goal     Funding target in wei.
    /// @param deadline Unix timestamp after which contributions are closed.
    event CampaignCreated(address indexed creator, string title, uint256 goal, uint256 deadline);

    /// @notice Emitted on every successful contribution.
    /// @param contributor   Address that sent the funds.
    /// @param amount        Amount contributed in this call (wei).
    /// @param totalRaised   Running total raised by the campaign after this call.
    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);

    /// @notice Emitted when the creator withdraws the raised funds on success.
    /// @param creator Address that received the funds.
    /// @param amount  Total amount withdrawn (wei).
    event Withdrawn(address indexed creator, uint256 amount);

    /// @notice Emitted when a contributor reclaims funds on failure.
    /// @param contributor Address that received the refund.
    /// @param amount      Amount refunded (wei).
    event Refunded(address indexed contributor, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The address allowed to withdraw funds if the goal is met.
    address public immutable creator;

    /// @notice The funding target in wei. Reaching or exceeding it marks success.
    uint256 public immutable goal;

    /// @notice Unix timestamp after which contributions are rejected.
    uint256 public immutable deadline;

    /// @notice Human-readable campaign title.
    string public title;

    /// @notice Total amount contributed across all contributors (wei).
    uint256 public totalRaised;

    /// @notice True once the creator has withdrawn the funds. Prevents double withdrawal.
    bool public withdrawn;

    /// @notice Per-contributor contributed amount, used to compute refunds.
    mapping(address => uint256) public contributions;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a campaign with fixed terms.
    /// @param _creator  Address entitled to withdraw on success. Must be non-zero.
    /// @param _title    Human-readable title.
    /// @param _goal     Funding target in wei. Must be non-zero.
    /// @param _deadline Unix timestamp strictly in the future.
    constructor(address _creator, string memory _title, uint256 _goal, uint256 _deadline) {
        if (_creator == address(0)) revert ZeroCreator();
        if (_goal == 0) revert ZeroGoal();
        if (_deadline <= block.timestamp) revert DeadlineInPast();

        creator = _creator;
        title = _title;
        goal = _goal;
        deadline = _deadline;

        emit CampaignCreated(_creator, _title, _goal, _deadline);
    }

    /*//////////////////////////////////////////////////////////////
                            MUTATIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Contribute ETH to the campaign before the deadline.
    /// @dev    Reverts after the deadline or on zero value. Updates the caller's
    ///         tracked contribution so they remain eligible for a refund on failure.
    function contribute() external payable {
        if (block.timestamp > deadline) revert CampaignEnded();
        if (msg.value == 0) revert ZeroContribution();

        // Effects: record before emitting; no external call here so ordering is
        // purely for clarity and consistent state in the event.
        contributions[msg.sender] += msg.value;
        uint256 raised = totalRaised + msg.value;
        totalRaised = raised;

        emit Contributed(msg.sender, msg.value, raised);
    }

    /// @notice Withdraw the full raised balance to the creator once the goal is met.
    /// @dev    Callable only by the creator and only once. Reaching the goal is a
    ///         success condition that holds even before the deadline, so the creator
    ///         need not wait. Follows checks-effects-interactions.
    function withdraw() external {
        if (msg.sender != creator) revert NotCreator();
        if (totalRaised < goal) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        // Effects.
        withdrawn = true;
        uint256 amount = address(this).balance;

        // Interaction.
        emit Withdrawn(creator, amount);
        _safeTransfer(creator, amount);
    }

    /// @notice Reclaim your contribution after a failed campaign.
    /// @dev    Only valid once the deadline has passed and the goal was not reached.
    ///         Zeroes the caller's contribution before transferring (CEI) to block
    ///         reentrancy and double-refunds.
    function refund() external {
        if (block.timestamp <= deadline) revert CampaignNotEnded();
        if (totalRaised >= goal) revert GoalReached();

        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToRefund();

        // Effects.
        contributions[msg.sender] = 0;

        // Interaction.
        emit Refunded(msg.sender, amount);
        _safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

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

    /// @dev Forwards all gas and bubbles up failure as {TransferFailed}.
    /// @param to     Recipient of the ETH.
    /// @param amount Amount to send in wei.
    function _safeTransfer(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
