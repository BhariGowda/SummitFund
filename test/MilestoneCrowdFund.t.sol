// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MilestoneCrowdFund} from "../src/MilestoneCrowdFund.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title MilestoneCrowdFundTest
/// @notice Unit, edge-case, and fuzz coverage for {MilestoneCrowdFund}.
contract MilestoneCrowdFundTest is Test {
    MilestoneCrowdFund internal campaign;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    string internal constant TITLE = "Build a Bridge";
    uint256 internal constant GOAL = 10 ether;
    uint256 internal DEADLINE;

    // Milestone schedule summing to GOAL: 2 / 3 / 5 ether.
    uint256 internal constant M0 = 2 ether;
    uint256 internal constant M1 = 3 ether;
    uint256 internal constant M2 = 5 ether;

    // Mirror the contract's events for expectEmit assertions.
    event CampaignCreated(address indexed creator, string title, uint256 goal, uint256 deadline, uint256 milestoneCount);
    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);
    event MilestoneRequested(uint256 indexed index, uint256 amount);
    event MilestoneVoted(
        uint256 indexed index,
        address indexed voter,
        bool approve,
        uint256 weight,
        uint256 approveVotes,
        uint256 rejectVotes
    );
    event MilestoneApproved(uint256 indexed index);
    event MilestoneRejected(uint256 indexed index, uint256 refundPool);
    event MilestoneClaimed(uint256 indexed index, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);

    function setUp() public {
        DEADLINE = block.timestamp + 7 days;
        campaign = new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, DEADLINE, _schedule(), _descriptions());

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _schedule() internal pure returns (uint256[] memory m) {
        m = new uint256[](3);
        m[0] = M0;
        m[1] = M1;
        m[2] = M2;
    }

    /// @dev Descriptions parallel to {_schedule}'s three-milestone amounts.
    function _descriptions() internal pure returns (string[] memory d) {
        d = new string[](3);
        d[0] = "Design";
        d[1] = "Build";
        d[2] = "Launch";
    }

    /// @dev `n` generic, non-empty milestone descriptions for custom-length schedules.
    function _descsFor(uint256 n) internal pure returns (string[] memory d) {
        d = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            d[i] = "milestone";
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsState() public view {
        assertEq(campaign.creator(), creator);
        assertEq(campaign.title(), TITLE);
        assertEq(campaign.goal(), GOAL);
        assertEq(campaign.deadline(), DEADLINE);
        assertEq(campaign.totalRaised(), 0);
        assertEq(campaign.milestoneCount(), 3);
        assertEq(campaign.milestones(0), M0);
        assertEq(campaign.milestones(1), M1);
        assertEq(campaign.milestones(2), M2);
        assertEq(campaign.nextMilestone(), 0);
        assertFalse(campaign.rejected());
        assertTrue(campaign.isFunding());
    }

    function test_Constructor_EmitsCampaignCreated() public {
        vm.expectEmit(true, false, false, true);
        emit CampaignCreated(creator, TITLE, GOAL, DEADLINE, 3);
        new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, DEADLINE, _schedule(), _descriptions());
    }

    function test_Constructor_RevertsZeroCreator() public {
        vm.expectRevert(MilestoneCrowdFund.ZeroCreator.selector);
        new MilestoneCrowdFund(address(0), address(0), TITLE, GOAL, DEADLINE, _schedule(), _descriptions());
    }

    function test_Constructor_RevertsZeroGoal() public {
        uint256[] memory m = new uint256[](1);
        m[0] = 1; // non-zero milestone but zero goal -> ZeroGoal fires first.
        vm.expectRevert(MilestoneCrowdFund.ZeroGoal.selector);
        new MilestoneCrowdFund(creator, address(0), TITLE, 0, DEADLINE, m, _descsFor(1));
    }

    function test_Constructor_RevertsDeadlineInPast() public {
        vm.expectRevert(MilestoneCrowdFund.DeadlineInPast.selector);
        new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, block.timestamp, _schedule(), _descriptions());
    }

    function test_Constructor_RevertsNoMilestones() public {
        uint256[] memory m = new uint256[](0);
        vm.expectRevert(MilestoneCrowdFund.NoMilestones.selector);
        new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, DEADLINE, m, _descsFor(0));
    }

    function test_Constructor_RevertsZeroMilestone() public {
        uint256[] memory m = new uint256[](2);
        m[0] = GOAL;
        m[1] = 0;
        vm.expectRevert(MilestoneCrowdFund.ZeroMilestone.selector);
        new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, DEADLINE, m, _descsFor(2));
    }

    function test_Constructor_RevertsSumTooLow() public {
        uint256[] memory m = new uint256[](2);
        m[0] = 1 ether;
        m[1] = 1 ether; // sums to 2, goal is 10.
        vm.expectRevert(MilestoneCrowdFund.MilestoneSumMismatch.selector);
        new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, DEADLINE, m, _descsFor(2));
    }

    function test_Constructor_RevertsSumTooHigh() public {
        uint256[] memory m = new uint256[](2);
        m[0] = 6 ether;
        m[1] = 6 ether; // sums to 12, goal is 10.
        vm.expectRevert(MilestoneCrowdFund.MilestoneSumMismatch.selector);
        new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, DEADLINE, m, _descsFor(2));
    }

    function test_Constructor_StoresDescriptions() public view {
        assertEq(campaign.descriptions(0), "Design");
        assertEq(campaign.descriptions(1), "Build");
        assertEq(campaign.descriptions(2), "Launch");
    }

    function test_MilestoneDescription_ReturnsStored() public view {
        assertEq(campaign.milestoneDescription(0), "Design");
        assertEq(campaign.milestoneDescription(2), "Launch");
    }

    function test_MilestoneDescription_RevertsOutOfRange() public {
        vm.expectRevert(MilestoneCrowdFund.InvalidMilestone.selector);
        campaign.milestoneDescription(3);
    }

    function test_Constructor_RevertsDescriptionCountMismatch() public {
        // Three amounts but only two descriptions.
        string[] memory d = new string[](2);
        d[0] = "a";
        d[1] = "b";
        vm.expectRevert(MilestoneCrowdFund.MilestoneCountMismatch.selector);
        new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, DEADLINE, _schedule(), d);
    }

    function test_Constructor_SingleMilestoneOk() public {
        uint256[] memory m = new uint256[](1);
        m[0] = GOAL;
        MilestoneCrowdFund c = new MilestoneCrowdFund(creator, address(0), TITLE, GOAL, DEADLINE, m, _descsFor(1));
        assertEq(c.milestoneCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                               CONTRIBUTE
    //////////////////////////////////////////////////////////////*/

    function test_Contribute_UpdatesState() public {
        vm.prank(alice);
        campaign.contribute{value: 1 ether}();
        assertEq(campaign.totalRaised(), 1 ether);
        assertEq(campaign.contributions(alice), 1 ether);
        assertEq(address(campaign).balance, 1 ether);
    }

    function test_Contribute_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Contributed(alice, 1 ether, 1 ether);
        vm.prank(alice);
        campaign.contribute{value: 1 ether}();
    }

    function test_Contribute_Accumulates() public {
        vm.startPrank(alice);
        campaign.contribute{value: 1 ether}();
        campaign.contribute{value: 2 ether}();
        vm.stopPrank();
        assertEq(campaign.contributions(alice), 3 ether);
    }

    function test_Contribute_RevertsZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.ZeroContribution.selector);
        campaign.contribute{value: 0}();
    }

    function test_Contribute_RevertsAfterDeadline() public {
        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.CampaignEnded.selector);
        campaign.contribute{value: 1 ether}();
    }

    function test_Contribute_RevertsOnTokenEntrypointForEthCampaign() public {
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.NotTokenCampaign.selector);
        campaign.contribute(1 ether);
    }

    function test_Contribute_ClosesAtGoal() public {
        _fundToGoal();
        assertTrue(campaign.goalReached());
        assertFalse(campaign.isFunding());

        vm.prank(bob);
        vm.expectRevert(MilestoneCrowdFund.FundingClosed.selector);
        campaign.contribute{value: 1 ether}();
    }

    function test_Contribute_OvershootGoalInOneTx() public {
        vm.prank(alice);
        campaign.contribute{value: 12 ether}();
        assertEq(campaign.totalRaised(), 12 ether);
        assertTrue(campaign.goalReached());
        // Funding now closed even though we overshot.
        vm.prank(bob);
        vm.expectRevert(MilestoneCrowdFund.FundingClosed.selector);
        campaign.contribute{value: 1 ether}();
    }

    /*//////////////////////////////////////////////////////////////
                          REQUEST MILESTONE
    //////////////////////////////////////////////////////////////*/

    function test_RequestMilestone_HappyPath() public {
        _fundToGoal();
        vm.expectEmit(true, false, false, true);
        emit MilestoneRequested(0, M0);
        vm.prank(creator);
        campaign.requestMilestone(0);
        (, MilestoneCrowdFund.Status state,,) = campaign.getMilestone(0);
        assertEq(uint256(state), uint256(MilestoneCrowdFund.Status.Active));
    }

    function test_RequestMilestone_RevertsNotCreator() public {
        _fundToGoal();
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.NotCreator.selector);
        campaign.requestMilestone(0);
    }

    function test_RequestMilestone_RevertsBeforeGoal() public {
        vm.prank(alice);
        campaign.contribute{value: 1 ether}();
        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdFund.GoalNotReached.selector);
        campaign.requestMilestone(0);
    }

    function test_RequestMilestone_RevertsOutOfRange() public {
        _fundToGoal();
        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdFund.InvalidMilestone.selector);
        campaign.requestMilestone(3);
    }

    function test_RequestMilestone_RevertsOutOfSequence() public {
        _fundToGoal();
        // Cannot jump to milestone 1 before 0 is done.
        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdFund.NotNextMilestone.selector);
        campaign.requestMilestone(1);
    }

    function test_RequestMilestone_RevertsDoubleRequest() public {
        _fundToGoal();
        vm.startPrank(creator);
        campaign.requestMilestone(0);
        vm.expectRevert(MilestoneCrowdFund.MilestoneNotPending.selector);
        campaign.requestMilestone(0);
        vm.stopPrank();
    }

    function test_RequestMilestone_SequentialAfterClaim() public {
        _fundToGoal();
        _approveAndClaim(0);
        assertEq(campaign.nextMilestone(), 1);

        vm.prank(creator);
        campaign.requestMilestone(1);
        (, MilestoneCrowdFund.Status state,,) = campaign.getMilestone(1);
        assertEq(uint256(state), uint256(MilestoneCrowdFund.Status.Active));
    }

    /*//////////////////////////////////////////////////////////////
                             VOTE MILESTONE
    //////////////////////////////////////////////////////////////*/

    function test_Vote_RevertsWhenNotActive() public {
        _fundToGoal();
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.MilestoneNotActive.selector);
        campaign.voteMilestone(0, true);
    }

    function test_Vote_RevertsNonContributor() public {
        _fundToGoal();
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.prank(bob); // bob never contributed in this setup
        vm.expectRevert(MilestoneCrowdFund.NotContributor.selector);
        campaign.voteMilestone(0, true);
    }

    function test_Vote_RevertsDoubleVote() public {
        // Split funders so alice's first vote (4 of 10) does not finalize the milestone.
        _splitFund();
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.startPrank(alice);
        campaign.voteMilestone(0, true);
        vm.expectRevert(MilestoneCrowdFund.AlreadyVoted.selector);
        campaign.voteMilestone(0, true);
        vm.stopPrank();
    }

    function test_Vote_EmitsEvent() public {
        _splitFund(); // alice 4, bob 6
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.expectEmit(true, true, false, true);
        emit MilestoneVoted(0, alice, true, 4 ether, 4 ether, 0);
        vm.prank(alice);
        campaign.voteMilestone(0, true);
    }

    function test_Vote_ApprovesOnStrictMajority() public {
        _splitFund(); // alice 4, bob 6, total 10
        vm.prank(creator);
        campaign.requestMilestone(0);

        // bob alone (6) > 5 = strict majority -> approved.
        vm.expectEmit(true, false, false, false);
        emit MilestoneApproved(0);
        vm.prank(bob);
        campaign.voteMilestone(0, true);

        (, MilestoneCrowdFund.Status state,,) = campaign.getMilestone(0);
        assertEq(uint256(state), uint256(MilestoneCrowdFund.Status.Approved));
    }

    function test_Vote_ExactHalfApproveIsNotEnough() public {
        _evenSplitFund(); // alice 5, bob 5, total 10
        vm.prank(creator);
        campaign.requestMilestone(0);

        // alice 5 -> 5*2 = 10, not > 10, so still active.
        vm.prank(alice);
        campaign.voteMilestone(0, true);
        (, MilestoneCrowdFund.Status state,,) = campaign.getMilestone(0);
        assertEq(uint256(state), uint256(MilestoneCrowdFund.Status.Active));

        // bob approves too -> 10*2 > 10 -> approved.
        vm.prank(bob);
        campaign.voteMilestone(0, true);
        (, state,,) = campaign.getMilestone(0);
        assertEq(uint256(state), uint256(MilestoneCrowdFund.Status.Approved));
    }

    function test_Vote_RejectsWhenHalfOpposes() public {
        _evenSplitFund(); // alice 5, bob 5
        vm.prank(creator);
        campaign.requestMilestone(0);

        // alice rejects with 5 -> 5*2 >= 10 -> approval impossible -> rejected.
        vm.expectEmit(true, false, false, true);
        emit MilestoneRejected(0, GOAL);
        vm.prank(alice);
        campaign.voteMilestone(0, false);

        (, MilestoneCrowdFund.Status state,,) = campaign.getMilestone(0);
        assertEq(uint256(state), uint256(MilestoneCrowdFund.Status.Rejected));
        assertTrue(campaign.rejected());
        assertEq(campaign.refundPool(), GOAL);
    }

    function test_Vote_RejectsWhenMajorityOpposes() public {
        _splitFund(); // alice 4, bob 6
        vm.prank(creator);
        campaign.requestMilestone(0);

        vm.prank(bob); // 6 reject -> 12 >= 10 -> rejected
        campaign.voteMilestone(0, false);
        assertTrue(campaign.rejected());
    }

    function test_Vote_CannotVoteAfterFinalized() public {
        _splitFund(); // alice 4, bob 6
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.prank(bob); // approves and finalizes
        campaign.voteMilestone(0, true);

        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.MilestoneNotActive.selector);
        campaign.voteMilestone(0, false);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM MILESTONE
    //////////////////////////////////////////////////////////////*/

    function test_Claim_TransfersAmount() public {
        _fundToGoal();
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.prank(alice);
        campaign.voteMilestone(0, true); // alice has 100% -> approved

        uint256 before = creator.balance;
        vm.expectEmit(true, false, false, true);
        emit MilestoneClaimed(0, M0);
        vm.prank(creator);
        campaign.claimMilestone(0);

        assertEq(creator.balance, before + M0);
        assertEq(address(campaign).balance, GOAL - M0);
        assertEq(campaign.nextMilestone(), 1);
        (, MilestoneCrowdFund.Status state,,) = campaign.getMilestone(0);
        assertEq(uint256(state), uint256(MilestoneCrowdFund.Status.Claimed));
    }

    function test_Claim_RevertsNotCreator() public {
        _fundToGoal();
        _approve(0);
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.NotCreator.selector);
        campaign.claimMilestone(0);
    }

    function test_Claim_RevertsNotApproved() public {
        _fundToGoal();
        vm.prank(creator);
        campaign.requestMilestone(0);
        // not yet voted/approved
        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdFund.MilestoneNotApproved.selector);
        campaign.claimMilestone(0);
    }

    function test_Claim_RevertsDoubleClaim() public {
        _fundToGoal();
        _approve(0);
        vm.startPrank(creator);
        campaign.claimMilestone(0);
        vm.expectRevert(MilestoneCrowdFund.MilestoneNotApproved.selector);
        campaign.claimMilestone(0);
        vm.stopPrank();
    }

    function test_Claim_FullSequenceDrainsContract() public {
        _fundToGoal();
        _approveAndClaim(0);
        _approveAndClaim(1);
        _approveAndClaim(2);

        assertEq(creator.balance, GOAL);
        assertEq(address(campaign).balance, 0);
        assertEq(campaign.nextMilestone(), 3);
    }

    function test_Claim_RequestAfterHaltReverts() public {
        _evenSplitFund();
        _approveAndClaimEven(0); // milestone 0 claimed via even split

        // Now reject milestone 1.
        vm.prank(creator);
        campaign.requestMilestone(1);
        vm.prank(alice);
        campaign.voteMilestone(1, false); // 5*2 >= 10 -> rejected
        assertTrue(campaign.rejected());

        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdFund.CampaignHalted.selector);
        campaign.requestMilestone(2);
    }

    /*//////////////////////////////////////////////////////////////
                          PRO-RATA REFUND
    //////////////////////////////////////////////////////////////*/

    function test_ClaimRefund_RevertsWhenNotRejected() public {
        _fundToGoal();
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.NotRejected.selector);
        campaign.claimRefund();
    }

    function test_ClaimRefund_ProRataAfterRejectionAtStart() public {
        _splitFund(); // alice 4, bob 6, total 10
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.prank(bob);
        campaign.voteMilestone(0, false); // reject, pool = 10

        assertEq(campaign.refundPool(), GOAL);
        assertEq(campaign.refundOwed(alice), 4 ether);
        assertEq(campaign.refundOwed(bob), 6 ether);

        uint256 aBefore = alice.balance;
        uint256 bBefore = bob.balance;
        vm.prank(alice);
        campaign.claimRefund();
        vm.prank(bob);
        campaign.claimRefund();

        assertEq(alice.balance, aBefore + 4 ether);
        assertEq(bob.balance, bBefore + 6 ether);
        assertEq(address(campaign).balance, 0);
    }

    function test_ClaimRefund_ProRataOnRemainingPoolAfterPartialRelease() public {
        _splitFund(); // alice 4, bob 6, total 10
        _approve(0); // approve milestone 0 (needs bob's 6 -> >5)
        vm.prank(creator);
        campaign.claimMilestone(0); // 2 ether out, 8 remain

        // Now reject milestone 1.
        vm.prank(creator);
        campaign.requestMilestone(1);
        vm.prank(bob);
        campaign.voteMilestone(1, false); // reject, pool = 8

        assertEq(campaign.refundPool(), 8 ether);
        // alice share 4/10 of 8 = 3.2; bob 6/10 of 8 = 4.8
        assertEq(campaign.refundOwed(alice), 3.2 ether);
        assertEq(campaign.refundOwed(bob), 4.8 ether);

        uint256 aBefore = alice.balance;
        vm.prank(alice);
        campaign.claimRefund();
        assertEq(alice.balance, aBefore + 3.2 ether);

        uint256 bBefore = bob.balance;
        vm.prank(bob);
        campaign.claimRefund();
        assertEq(bob.balance, bBefore + 4.8 ether);

        assertEq(address(campaign).balance, 0);
    }

    function test_ClaimRefund_EmitsEvent() public {
        _splitFund();
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.prank(bob);
        campaign.voteMilestone(0, false);

        vm.expectEmit(true, false, false, true);
        emit Refunded(alice, 4 ether);
        vm.prank(alice);
        campaign.claimRefund();
    }

    function test_ClaimRefund_RevertsDoubleClaim() public {
        _splitFund();
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.prank(bob);
        campaign.voteMilestone(0, false);

        vm.startPrank(alice);
        campaign.claimRefund();
        vm.expectRevert(MilestoneCrowdFund.NothingToRefund.selector);
        campaign.claimRefund();
        vm.stopPrank();
    }

    function test_ClaimRefund_RevertsNonContributor() public {
        _splitFund();
        vm.prank(creator);
        campaign.requestMilestone(0);
        vm.prank(bob);
        campaign.voteMilestone(0, false);

        vm.prank(carol); // never contributed
        vm.expectRevert(MilestoneCrowdFund.NothingToRefund.selector);
        campaign.claimRefund();
    }

    function test_RefundOwed_ZeroBeforeRejection() public {
        _splitFund();
        assertEq(campaign.refundOwed(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       FAILED-FUNDING REFUND
    //////////////////////////////////////////////////////////////*/

    function test_Refund_FailedFundingReturnsFull() public {
        vm.prank(alice);
        campaign.contribute{value: 3 ether}();
        vm.prank(bob);
        campaign.contribute{value: 2 ether}();

        vm.warp(DEADLINE + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        campaign.refund();
        assertEq(alice.balance, before + 3 ether);
        assertEq(campaign.contributions(alice), 0);
    }

    function test_Refund_RevertsBeforeDeadline() public {
        vm.prank(alice);
        campaign.contribute{value: 3 ether}();
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.CampaignNotEnded.selector);
        campaign.refund();
    }

    function test_Refund_RevertsWhenGoalReached() public {
        _fundToGoal();
        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.GoalReached.selector);
        campaign.refund();
    }

    function test_Refund_RevertsNothingToRefund() public {
        vm.warp(DEADLINE + 1);
        vm.prank(bob);
        vm.expectRevert(MilestoneCrowdFund.NothingToRefund.selector);
        campaign.refund();
    }

    function test_Refund_RevertsDoubleRefund() public {
        vm.prank(alice);
        campaign.contribute{value: 3 ether}();
        vm.warp(DEADLINE + 1);
        vm.startPrank(alice);
        campaign.refund();
        vm.expectRevert(MilestoneCrowdFund.NothingToRefund.selector);
        campaign.refund();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                ERC20
    //////////////////////////////////////////////////////////////*/

    function test_ERC20_FullMilestoneFlow() public {
        MockERC20 mtk = new MockERC20();
        MilestoneCrowdFund c = new MilestoneCrowdFund(creator, address(mtk), TITLE, GOAL, DEADLINE, _schedule(), _descriptions());

        mtk.mint(alice, GOAL);
        vm.startPrank(alice);
        mtk.approve(address(c), GOAL);
        c.contribute(GOAL);
        vm.stopPrank();

        assertTrue(c.isERC20());
        assertEq(c.totalRaised(), GOAL);

        // Drive all three milestones with alice (100% weight).
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(creator);
            c.requestMilestone(i);
            vm.prank(alice);
            c.voteMilestone(i, true);
            vm.prank(creator);
            c.claimMilestone(i);
        }

        assertEq(mtk.balanceOf(creator), GOAL);
        assertEq(mtk.balanceOf(address(c)), 0);
    }

    function test_ERC20_ProRataRefundOnRejection() public {
        MockERC20 mtk = new MockERC20();
        MilestoneCrowdFund c = new MilestoneCrowdFund(creator, address(mtk), TITLE, GOAL, DEADLINE, _schedule(), _descriptions());

        mtk.mint(alice, 4 ether);
        mtk.mint(bob, 6 ether);
        vm.startPrank(alice);
        mtk.approve(address(c), 4 ether);
        c.contribute(4 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        mtk.approve(address(c), 6 ether);
        c.contribute(6 ether);
        vm.stopPrank();

        vm.prank(creator);
        c.requestMilestone(0);
        vm.prank(bob);
        c.voteMilestone(0, false); // reject

        vm.prank(alice);
        c.claimRefund();
        vm.prank(bob);
        c.claimRefund();

        assertEq(mtk.balanceOf(alice), 4 ether);
        assertEq(mtk.balanceOf(bob), 6 ether);
        assertEq(mtk.balanceOf(address(c)), 0);
    }

    function test_ERC20_RevertsEthEntrypoint() public {
        MockERC20 mtk = new MockERC20();
        MilestoneCrowdFund c = new MilestoneCrowdFund(creator, address(mtk), TITLE, GOAL, DEADLINE, _schedule(), _descriptions());
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdFund.NotEthCampaign.selector);
        c.contribute{value: 1 ether}();
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_GetMilestone_RevertsOutOfRange() public {
        vm.expectRevert(MilestoneCrowdFund.InvalidMilestone.selector);
        campaign.getMilestone(3);
    }

    function test_Reentrancy_GuardBlocksReentrantClaim() public {
        // A malicious creator that re-enters claimMilestone during ETH payout.
        ReentrantCreator bad = new ReentrantCreator();
        MilestoneCrowdFund c = new MilestoneCrowdFund(address(bad), address(0), TITLE, GOAL, DEADLINE, _schedule(), _descriptions());
        bad.setTarget(c);

        vm.prank(alice);
        c.contribute{value: GOAL}();
        vm.prank(address(bad));
        c.requestMilestone(0);
        vm.prank(alice);
        c.voteMilestone(0, true);

        // The reentrant receive() attempts a nested claim; the guard turns the nested
        // call into a revert, which bubbles up as a failed ETH transfer.
        bad.arm();
        vm.prank(address(bad));
        vm.expectRevert(MilestoneCrowdFund.TransferFailed.selector);
        c.claimMilestone(0);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ProRataRefundConserves(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1 ether, 100 ether));
        b = uint96(bound(b, 1 ether, 100 ether));
        uint256 total = uint256(a) + uint256(b);

        uint256[] memory m = new uint256[](1);
        m[0] = total;
        MilestoneCrowdFund c = new MilestoneCrowdFund(creator, address(0), TITLE, total, DEADLINE, m, _descsFor(1));

        vm.deal(alice, a);
        vm.deal(bob, b);
        vm.prank(alice);
        c.contribute{value: a}();
        vm.prank(bob);
        c.contribute{value: b}();

        vm.prank(creator);
        c.requestMilestone(0);
        // Whichever single voter holds >= half can force rejection. Have both reject.
        vm.prank(alice);
        c.voteMilestone(0, false);
        if (!c.rejected()) {
            vm.prank(bob);
            c.voteMilestone(0, false);
        }
        assertTrue(c.rejected());

        vm.prank(alice);
        c.claimRefund();
        vm.prank(bob);
        c.claimRefund();

        // Pro-rata payouts never exceed the pool; only integer dust may remain.
        assertLe(address(c).balance, 1);
    }

    function testFuzz_ApprovalThreshold(uint96 raise) public {
        uint256 total = uint256(bound(raise, 2 ether, 100 ether));
        uint256[] memory m = new uint256[](1);
        m[0] = total;
        MilestoneCrowdFund c = new MilestoneCrowdFund(creator, address(0), TITLE, total, DEADLINE, m, _descsFor(1));

        // alice exactly half, bob exactly half (total is even-bounded? not necessarily).
        uint256 half = total / 2;
        uint256 rest = total - half;
        vm.deal(alice, half == 0 ? 1 : half);
        vm.deal(bob, rest);
        if (half > 0) {
            vm.prank(alice);
            c.contribute{value: half}();
        }
        vm.prank(bob);
        c.contribute{value: rest}();

        vm.prank(creator);
        c.requestMilestone(0);

        // bob alone approves: passes iff rest*2 > total.
        vm.prank(bob);
        c.voteMilestone(0, true);
        (, MilestoneCrowdFund.Status state,,) = c.getMilestone(0);
        bool approved = uint256(state) == uint256(MilestoneCrowdFund.Status.Approved);
        assertEq(approved, rest * 2 > total);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fundToGoal() internal {
        vm.prank(alice);
        campaign.contribute{value: GOAL}();
    }

    /// @dev alice 4 ether, bob 6 ether.
    function _splitFund() internal {
        vm.prank(alice);
        campaign.contribute{value: 4 ether}();
        vm.prank(bob);
        campaign.contribute{value: 6 ether}();
    }

    /// @dev alice 5 ether, bob 5 ether.
    function _evenSplitFund() internal {
        vm.prank(alice);
        campaign.contribute{value: 5 ether}();
        vm.prank(bob);
        campaign.contribute{value: 5 ether}();
    }

    /// @dev Request and approve milestone `i`. Works for both full-goal (alice holds all)
    ///      and split (alice 4 / bob 6) funding: alice votes first, and bob tops up the
    ///      approval weight if alice alone was not a strict majority.
    function _approve(uint256 i) internal {
        vm.prank(creator);
        campaign.requestMilestone(i);
        vm.prank(alice);
        campaign.voteMilestone(i, true);
        (, MilestoneCrowdFund.Status state,,) = campaign.getMilestone(i);
        if (uint256(state) != uint256(MilestoneCrowdFund.Status.Approved) && campaign.contributions(bob) > 0) {
            vm.prank(bob);
            campaign.voteMilestone(i, true);
        }
    }

    function _approveAndClaim(uint256 i) internal {
        vm.prank(creator);
        campaign.requestMilestone(i);
        vm.prank(alice);
        campaign.voteMilestone(i, true);
        vm.prank(creator);
        campaign.claimMilestone(i);
    }

    /// @dev Even-split variant: both vote to approve, then claim.
    function _approveAndClaimEven(uint256 i) internal {
        vm.prank(creator);
        campaign.requestMilestone(i);
        vm.prank(alice);
        campaign.voteMilestone(i, true);
        vm.prank(bob);
        campaign.voteMilestone(i, true);
        vm.prank(creator);
        campaign.claimMilestone(i);
    }
}

/// @dev Creator contract that attempts to re-enter {claimMilestone} when it receives ETH.
contract ReentrantCreator {
    MilestoneCrowdFund internal target;
    bool internal armed;

    function setTarget(MilestoneCrowdFund _t) external {
        target = _t;
    }

    function arm() external {
        armed = true;
    }

    function requestMilestone(uint256 i) external {
        target.requestMilestone(i);
    }

    function claimMilestone(uint256 i) external {
        target.claimMilestone(i);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            target.claimMilestone(0); // nested call hits the reentrancy guard
        }
    }
}
