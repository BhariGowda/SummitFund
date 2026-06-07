// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";

/// @title MilestoneCrowdFund
/// @author crowdfund-dapp
/// @notice A crowdfunding campaign that releases escrowed funds to the creator in
///         contributor-governed milestones rather than a single lump withdrawal.
/// @dev    One deployed instance represents exactly one campaign. Like {CrowdFund} it
///         denominates funds in either native ETH (`token == address(0)`) or a single
///         ERC20 token fixed at construction, and credits the amount actually received
///         so fee-on-transfer tokens are handled correctly.
///
///         Lifecycle:
///           1. Funding   — contributors call {contribute} until the goal is reached
///                          (funding then closes) or the deadline passes. If the deadline
///                          passes without reaching the goal the campaign has failed and
///                          contributors reclaim their full contribution via {refund}.
///           2. Execution — once the goal is reached the creator drives the milestones in
///                          order: {requestMilestone} opens a vote, contributors weigh in
///                          with {voteMilestone}, and once a strict majority of all
///                          contributed value approves, the creator pulls that milestone's
///                          amount with {claimMilestone}. The next milestone may only be
///                          requested after the previous one is claimed.
///           3. Rejection — if a milestone vote gathers enough opposition that approval
///                          becomes impossible it is rejected, the campaign halts, and the
///                          remaining escrow is refunded pro-rata via {claimRefund}.
///
///         Voting weight is a contributor's {contributions} balance, which is frozen once
///         funding closes, so milestone tallies are stable across the execution phase. A
///         milestone needs `approveVotes * 2 > totalRaised` to pass and is rejected once
///         `rejectVotes * 2 >= totalRaised` makes that impossible.
contract MilestoneCrowdFund {
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
    /// @notice Thrown when no milestones are supplied at construction.
    error NoMilestones();
    /// @notice Thrown when any supplied milestone amount is zero.
    error ZeroMilestone();
    /// @notice Thrown when the supplied milestone amounts do not sum to the goal.
    error MilestoneSumMismatch();
    /// @notice Thrown when contributing after the deadline has passed.
    error CampaignEnded();
    /// @notice Thrown when contributing after the goal has been reached (funding closed).
    error FundingClosed();
    /// @notice Thrown when a contribution carries zero value.
    error ZeroContribution();
    /// @notice Thrown when the ETH `contribute()` entrypoint is used on a token campaign.
    error NotEthCampaign();
    /// @notice Thrown when the ERC20 `contribute(uint256)` entrypoint is used on an ETH campaign.
    error NotTokenCampaign();
    /// @notice Thrown when a milestone action is attempted before the goal is reached.
    error GoalNotReached();
    /// @notice Thrown when a milestone index is out of range.
    error InvalidMilestone();
    /// @notice Thrown when requesting a milestone out of sequence.
    error NotNextMilestone();
    /// @notice Thrown when requesting a milestone that is not in the uninitialized state.
    error MilestoneNotPending();
    /// @notice Thrown when voting on or claiming a milestone that is not open for voting.
    error MilestoneNotActive();
    /// @notice Thrown when claiming a milestone that has not been approved.
    error MilestoneNotApproved();
    /// @notice Thrown when an address with no contribution attempts to vote.
    error NotContributor();
    /// @notice Thrown when a contributor votes twice on the same milestone.
    error AlreadyVoted();
    /// @notice Thrown when the creator acts after a milestone has been rejected.
    error CampaignHalted();
    /// @notice Thrown when refunding a failed-funding campaign before the deadline passes.
    error CampaignNotEnded();
    /// @notice Thrown when refunding a campaign whose goal was reached without a rejection.
    error GoalReached();
    /// @notice Thrown when a pro-rata refund is claimed before any milestone is rejected.
    error NotRejected();
    /// @notice Thrown when an address with nothing to reclaim requests a refund.
    error NothingToRefund();
    /// @notice Thrown when the low-level ETH transfer fails.
    error TransferFailed();
    /// @notice Thrown when an ERC20 transfer or transferFrom fails.
    error TokenTransferFailed();
    /// @notice Thrown when a function guarded against reentrancy is re-entered.
    error Reentrancy();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Lifecycle state of a single milestone.
    /// @dev Pending is the implicit zero value: every milestone starts here.
    enum Status {
        Pending, // 0: not yet requested by the creator
        Active, //  1: requested; voting is open
        Approved, // 2: passed its vote; awaiting creator claim
        Claimed, //  3: funds released to the creator
        Rejected //  4: failed its vote; campaign halted
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once at construction with the campaign's immutable terms.
    event CampaignCreated(address indexed creator, string title, uint256 goal, uint256 deadline, uint256 milestoneCount);

    /// @notice Emitted on every successful contribution.
    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);

    /// @notice Emitted when the creator opens voting on a milestone.
    event MilestoneRequested(uint256 indexed index, uint256 amount);

    /// @notice Emitted on every milestone vote.
    /// @param approve     Whether the vote was in favor.
    /// @param weight      The voter's contribution-weighted voting power.
    /// @param approveVotes Running approval weight after this vote.
    /// @param rejectVotes  Running rejection weight after this vote.
    event MilestoneVoted(
        uint256 indexed index,
        address indexed voter,
        bool approve,
        uint256 weight,
        uint256 approveVotes,
        uint256 rejectVotes
    );

    /// @notice Emitted when a milestone's vote crosses the approval threshold.
    event MilestoneApproved(uint256 indexed index);

    /// @notice Emitted when a milestone's vote can no longer be approved.
    event MilestoneRejected(uint256 indexed index, uint256 refundPool);

    /// @notice Emitted when the creator pulls an approved milestone's funds.
    event MilestoneClaimed(uint256 indexed index, uint256 amount);

    /// @notice Emitted when a contributor reclaims funds (failed funding or rejection).
    event Refunded(address indexed contributor, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The address allowed to drive milestones and receive released funds.
    address public immutable creator;

    /// @notice The ERC20 token funds are denominated in, or `address(0)` for native ETH.
    address public immutable token;

    /// @notice The funding target in the campaign's unit. Equals the sum of all milestones.
    uint256 public immutable goal;

    /// @notice Unix timestamp after which contributions are rejected.
    uint256 public immutable deadline;

    /// @notice Human-readable campaign title.
    string public title;

    /// @notice Total amount contributed across all contributors (campaign unit).
    uint256 public totalRaised;

    /// @notice Per-contributor contributed amount: refund basis and voting weight.
    mapping(address => uint256) public contributions;

    /// @notice Ordered milestone amounts, summing to {goal}.
    uint256[] public milestones;

    /// @notice The index of the next milestone the creator may request.
    uint256 public nextMilestone;

    /// @notice Lifecycle state of each milestone, by index.
    mapping(uint256 => Status) public status;

    /// @notice Cumulative approval voting weight per milestone.
    mapping(uint256 => uint256) public approveVotes;

    /// @notice Cumulative rejection voting weight per milestone.
    mapping(uint256 => uint256) public rejectVotes;

    /// @notice Whether an address has already voted on a given milestone.
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice True once a milestone has been rejected and the campaign has halted.
    bool public rejected;

    /// @notice Escrow snapshot taken at rejection, used as the pro-rata refund basis.
    uint256 public refundPool;

    /// @notice Whether an address has already claimed its pro-rata refund.
    mapping(address => bool) public refundClaimed;

    /// @dev Reentrancy guard state. 1 = unlocked, 2 = locked.
    uint256 private _locked = 1;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Blocks reentrancy on the value-moving entrypoints.
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a milestone campaign with fixed terms.
    /// @param _creator    Address entitled to drive milestones. Must be non-zero.
    /// @param _token      ERC20 token to denominate the campaign in, or `address(0)` for ETH.
    /// @param _title      Human-readable title.
    /// @param _goal       Funding target in the campaign's unit. Must be non-zero.
    /// @param _deadline   Unix timestamp strictly in the future.
    /// @param _milestones Ordered milestone amounts; each non-zero and summing to `_goal`.
    constructor(
        address _creator,
        address _token,
        string memory _title,
        uint256 _goal,
        uint256 _deadline,
        uint256[] memory _milestones
    ) {
        if (_creator == address(0)) revert ZeroCreator();
        if (_goal == 0) revert ZeroGoal();
        if (_deadline <= block.timestamp) revert DeadlineInPast();
        if (_milestones.length == 0) revert NoMilestones();

        uint256 sum;
        for (uint256 i = 0; i < _milestones.length; i++) {
            if (_milestones[i] == 0) revert ZeroMilestone();
            sum += _milestones[i];
        }
        if (sum != _goal) revert MilestoneSumMismatch();

        creator = _creator;
        token = _token;
        title = _title;
        goal = _goal;
        deadline = _deadline;
        milestones = _milestones;

        emit CampaignCreated(_creator, _title, _goal, _deadline, _milestones.length);
    }

    /*//////////////////////////////////////////////////////////////
                            FUNDING (PHASE 1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Contribute ETH to an ETH-denominated campaign while funding is open.
    /// @dev Reverts on a token campaign, after the deadline, once the goal is reached,
    ///      or on zero value.
    function contribute() external payable nonReentrant {
        if (token != address(0)) revert NotEthCampaign();
        _checkFundingOpen();
        if (msg.value == 0) revert ZeroContribution();

        _record(msg.sender, msg.value);
    }

    /// @notice Contribute ERC20 tokens to a token-denominated campaign while funding is open.
    /// @dev Pulls `amount` via `transferFrom` (caller must approve first) and credits the
    ///      balance delta, so fee-on-transfer tokens are accounted for correctly.
    /// @param amount The number of token base units to contribute.
    function contribute(uint256 amount) external nonReentrant {
        if (token == address(0)) revert NotTokenCampaign();
        _checkFundingOpen();
        if (amount == 0) revert ZeroContribution();

        uint256 before = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroContribution();

        _record(msg.sender, received);
    }

    /*//////////////////////////////////////////////////////////////
                          MILESTONES (PHASE 2)
    //////////////////////////////////////////////////////////////*/

    /// @notice Open contributor voting on the next milestone.
    /// @dev Callable only by the creator, only once the goal is reached, only while the
    ///      campaign is healthy, and only for the next milestone in sequence (the one
    ///      following the most recently claimed milestone).
    /// @param milestoneIndex The milestone to request. Must equal {nextMilestone}.
    function requestMilestone(uint256 milestoneIndex) external {
        if (msg.sender != creator) revert NotCreator();
        if (rejected) revert CampaignHalted();
        if (totalRaised < goal) revert GoalNotReached();
        if (milestoneIndex >= milestones.length) revert InvalidMilestone();
        if (milestoneIndex != nextMilestone) revert NotNextMilestone();
        if (status[milestoneIndex] != Status.Pending) revert MilestoneNotPending();

        status[milestoneIndex] = Status.Active;
        emit MilestoneRequested(milestoneIndex, milestones[milestoneIndex]);
    }

    /// @notice Cast a contribution-weighted vote on an open milestone.
    /// @dev Voting weight is the caller's {contributions} balance. Each contributor votes
    ///      at most once per milestone. The vote finalizes the milestone the moment a
    ///      threshold is crossed: approval at `approveVotes * 2 > totalRaised`, or rejection
    ///      at `rejectVotes * 2 >= totalRaised` (the point where approval is unreachable).
    /// @param milestoneIndex The milestone being voted on.
    /// @param approve        True to support release, false to oppose it.
    function voteMilestone(uint256 milestoneIndex, bool approve) external {
        if (status[milestoneIndex] != Status.Active) revert MilestoneNotActive();

        uint256 weight = contributions[msg.sender];
        if (weight == 0) revert NotContributor();
        if (hasVoted[milestoneIndex][msg.sender]) revert AlreadyVoted();

        hasVoted[milestoneIndex][msg.sender] = true;

        uint256 approved = approveVotes[milestoneIndex];
        uint256 rejectedWeight = rejectVotes[milestoneIndex];
        if (approve) {
            approved += weight;
            approveVotes[milestoneIndex] = approved;
        } else {
            rejectedWeight += weight;
            rejectVotes[milestoneIndex] = rejectedWeight;
        }

        emit MilestoneVoted(milestoneIndex, msg.sender, approve, weight, approved, rejectedWeight);

        if (approved * 2 > totalRaised) {
            status[milestoneIndex] = Status.Approved;
            emit MilestoneApproved(milestoneIndex);
        } else if (rejectedWeight * 2 >= totalRaised) {
            status[milestoneIndex] = Status.Rejected;
            rejected = true;
            uint256 pool = _balance();
            refundPool = pool;
            emit MilestoneRejected(milestoneIndex, pool);
        }
    }

    /// @notice Release an approved milestone's funds to the creator.
    /// @dev Callable only by the creator and only on an approved milestone. Advances
    ///      {nextMilestone} so the following milestone may be requested. Follows
    ///      checks-effects-interactions and is reentrancy-guarded.
    /// @param milestoneIndex The approved milestone to claim.
    function claimMilestone(uint256 milestoneIndex) external nonReentrant {
        if (msg.sender != creator) revert NotCreator();
        if (status[milestoneIndex] != Status.Approved) revert MilestoneNotApproved();

        // Effects.
        status[milestoneIndex] = Status.Claimed;
        nextMilestone = milestoneIndex + 1;
        uint256 amount = milestones[milestoneIndex];

        // Interaction.
        emit MilestoneClaimed(milestoneIndex, amount);
        _payout(creator, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                REFUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reclaim a pro-rata share of the remaining escrow after a milestone rejection.
    /// @dev The refund basis is the escrow snapshot taken at rejection; each contributor
    ///      receives `contribution * refundPool / totalRaised`. Callable once per address.
    function claimRefund() external nonReentrant {
        if (!rejected) revert NotRejected();

        uint256 contributed = contributions[msg.sender];
        if (contributed == 0 || refundClaimed[msg.sender]) revert NothingToRefund();

        uint256 amount = (contributed * refundPool) / totalRaised;
        if (amount == 0) revert NothingToRefund();

        // Effects.
        refundClaimed[msg.sender] = true;

        // Interaction.
        emit Refunded(msg.sender, amount);
        _payout(msg.sender, amount);
    }

    /// @notice Reclaim your full contribution after a failed funding round.
    /// @dev Only valid once the deadline has passed with the goal unmet. Distinct from the
    ///      milestone-rejection path served by {claimRefund}.
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
    function isERC20() external view returns (bool) {
        return token != address(0);
    }

    /// @notice The number of milestones in this campaign.
    function milestoneCount() external view returns (uint256) {
        return milestones.length;
    }

    /// @notice Whether the funding goal has been reached.
    function goalReached() external view returns (bool) {
        return totalRaised >= goal;
    }

    /// @notice Whether funding is still open (goal not yet reached and deadline not passed).
    function isFunding() external view returns (bool) {
        return totalRaised < goal && block.timestamp <= deadline;
    }

    /// @notice Convenience accessor for a milestone's amount and live vote state.
    /// @param index The milestone to inspect.
    /// @return amount   The milestone's release amount.
    /// @return state    The milestone's lifecycle status.
    /// @return approveW Cumulative approval weight.
    /// @return rejectW  Cumulative rejection weight.
    function getMilestone(uint256 index)
        external
        view
        returns (uint256 amount, Status state, uint256 approveW, uint256 rejectW)
    {
        if (index >= milestones.length) revert InvalidMilestone();
        return (milestones[index], status[index], approveVotes[index], rejectVotes[index]);
    }

    /// @notice The pro-rata refund an address could claim after a rejection.
    /// @dev Returns zero before any rejection or once the address has already claimed.
    function refundOwed(address account) external view returns (uint256) {
        if (!rejected || refundClaimed[account]) return 0;
        return (contributions[account] * refundPool) / totalRaised;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts unless funding is open: not past the deadline and not yet at the goal.
    function _checkFundingOpen() private view {
        if (block.timestamp > deadline) revert CampaignEnded();
        if (totalRaised >= goal) revert FundingClosed();
    }

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
    function _safeTransfer(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev ERC20 `transfer` tolerant of non-compliant tokens that return no data.
    function _safeTransferToken(address to, uint256 amount) private {
        _callToken(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    }

    /// @dev ERC20 `transferFrom` tolerant of non-compliant tokens that return no data.
    function _safeTransferFrom(address from, address to, uint256 amount) private {
        _callToken(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    }

    /// @dev Low-level call to {token} validating the optional boolean return.
    function _callToken(bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
    }
}
