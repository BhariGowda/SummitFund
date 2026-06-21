// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrowdFund} from "../src/CrowdFund.sol";

/// @title CrowdFundTest
/// @notice Unit, edge-case, and fuzz coverage for {CrowdFund}.
contract CrowdFundTest is Test {
    CrowdFund internal campaign;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    string internal constant TITLE = "Save the Whales";
    uint256 internal constant GOAL = 10 ether;
    uint256 internal DEADLINE;

    // Mirror the contract's events for expectEmit assertions.
    event CampaignCreated(address indexed creator, string title, uint256 goal, uint256 deadline);
    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);
    event Withdrawn(address indexed creator, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);

    function setUp() public {
        DEADLINE = block.timestamp + 7 days;
        campaign = new CrowdFund(creator, address(0), TITLE, GOAL, DEADLINE);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
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
        assertFalse(campaign.withdrawn());
        assertTrue(campaign.isActive());
    }

    function test_Constructor_EmitsCampaignCreated() public {
        vm.expectEmit(true, false, false, true);
        emit CampaignCreated(creator, TITLE, GOAL, DEADLINE);
        new CrowdFund(creator, address(0), TITLE, GOAL, DEADLINE);
    }

    function test_Constructor_RevertsZeroCreator() public {
        vm.expectRevert(CrowdFund.ZeroCreator.selector);
        new CrowdFund(address(0), address(0), TITLE, GOAL, DEADLINE);
    }

    function test_Constructor_RevertsZeroGoal() public {
        vm.expectRevert(CrowdFund.ZeroGoal.selector);
        new CrowdFund(creator, address(0), TITLE, 0, DEADLINE);
    }

    function test_Constructor_RevertsDeadlineInPast() public {
        vm.expectRevert(CrowdFund.DeadlineInPast.selector);
        new CrowdFund(creator, address(0), TITLE, GOAL, block.timestamp);
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

    function test_Contribute_Accumulates() public {
        vm.startPrank(alice);
        campaign.contribute{value: 1 ether}();
        campaign.contribute{value: 2 ether}();
        vm.stopPrank();

        assertEq(campaign.contributions(alice), 3 ether);
        assertEq(campaign.totalRaised(), 3 ether);
    }

    function test_Contribute_MultipleContributors() public {
        vm.prank(alice);
        campaign.contribute{value: 4 ether}();
        vm.prank(bob);
        campaign.contribute{value: 6 ether}();

        assertEq(campaign.totalRaised(), 10 ether);
        assertEq(campaign.contributions(alice), 4 ether);
        assertEq(campaign.contributions(bob), 6 ether);
        assertTrue(campaign.goalReached());
    }

    function test_Contribute_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Contributed(alice, 1 ether, 1 ether);
        vm.prank(alice);
        campaign.contribute{value: 1 ether}();
    }

    function test_Contribute_RevertsZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(CrowdFund.ZeroContribution.selector);
        campaign.contribute{value: 0}();
    }

    function test_Contribute_RevertsAfterDeadline() public {
        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(CrowdFund.CampaignEnded.selector);
        campaign.contribute{value: 1 ether}();
    }

    function test_Contribute_AllowedExactlyAtDeadline() public {
        vm.warp(DEADLINE); // boundary: still active (<=).
        vm.prank(alice);
        campaign.contribute{value: 1 ether}();
        assertEq(campaign.totalRaised(), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_TransfersToCreator() public {
        _fundToGoal();

        uint256 before = creator.balance;
        vm.prank(creator);
        campaign.withdraw();

        assertEq(creator.balance, before + GOAL);
        assertEq(address(campaign).balance, 0);
        assertTrue(campaign.withdrawn());
    }

    function test_Withdraw_WorksWhenOverfunded() public {
        vm.prank(alice);
        campaign.contribute{value: 15 ether}();

        vm.prank(creator);
        campaign.withdraw();
        assertEq(creator.balance, 15 ether);
    }

    function test_Withdraw_BeforeDeadlineWhenGoalMet() public {
        _fundToGoal();
        // Still before deadline; success condition met, so withdraw is allowed.
        assertTrue(campaign.isActive());
        vm.prank(creator);
        campaign.withdraw();
        assertTrue(campaign.withdrawn());
    }

    function test_Withdraw_EmitsEvent() public {
        _fundToGoal();
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(creator, GOAL);
        vm.prank(creator);
        campaign.withdraw();
    }

    function test_Withdraw_RevertsNotCreator() public {
        _fundToGoal();
        vm.prank(alice);
        vm.expectRevert(CrowdFund.NotCreator.selector);
        campaign.withdraw();
    }

    function test_Withdraw_RevertsGoalNotReached() public {
        vm.prank(alice);
        campaign.contribute{value: 1 ether}();
        vm.prank(creator);
        vm.expectRevert(CrowdFund.GoalNotReached.selector);
        campaign.withdraw();
    }

    function test_Withdraw_RevertsDoubleWithdraw() public {
        _fundToGoal();
        vm.startPrank(creator);
        campaign.withdraw();
        vm.expectRevert(CrowdFund.AlreadyWithdrawn.selector);
        campaign.withdraw();
        vm.stopPrank();
    }

    function test_Withdraw_RevertsWhenCreatorRejectsETH() public {
        // Deploy a campaign whose creator is a contract that rejects ETH.
        RejectETH badCreator = new RejectETH();
        CrowdFund c = new CrowdFund(address(badCreator), address(0), TITLE, GOAL, DEADLINE);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        c.contribute{value: GOAL}();

        vm.prank(address(badCreator));
        vm.expectRevert(CrowdFund.TransferFailed.selector);
        c.withdraw();
    }

    /*//////////////////////////////////////////////////////////////
                                 REFUND
    //////////////////////////////////////////////////////////////*/

    function test_Refund_ReturnsContribution() public {
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
        // Bob still has his share escrowed.
        assertEq(address(campaign).balance, 2 ether);
    }

    function test_Refund_EmitsEvent() public {
        vm.prank(alice);
        campaign.contribute{value: 3 ether}();
        vm.warp(DEADLINE + 1);

        vm.expectEmit(true, false, false, true);
        emit Refunded(alice, 3 ether);
        vm.prank(alice);
        campaign.refund();
    }

    function test_Refund_RevertsBeforeDeadline() public {
        vm.prank(alice);
        campaign.contribute{value: 3 ether}();
        vm.prank(alice);
        vm.expectRevert(CrowdFund.CampaignNotEnded.selector);
        campaign.refund();
    }

    function test_Refund_RevertsAtExactDeadline() public {
        vm.prank(alice);
        campaign.contribute{value: 3 ether}();
        vm.warp(DEADLINE); // boundary: not ended yet (<=).
        vm.prank(alice);
        vm.expectRevert(CrowdFund.CampaignNotEnded.selector);
        campaign.refund();
    }

    function test_Refund_RevertsWhenGoalReached() public {
        _fundToGoal();
        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(CrowdFund.GoalReached.selector);
        campaign.refund();
    }

    function test_Refund_RevertsNothingToRefund() public {
        vm.warp(DEADLINE + 1);
        vm.prank(bob);
        vm.expectRevert(CrowdFund.NothingToRefund.selector);
        campaign.refund();
    }

    function test_Refund_RevertsDoubleRefund() public {
        vm.prank(alice);
        campaign.contribute{value: 3 ether}();
        vm.warp(DEADLINE + 1);
        vm.startPrank(alice);
        campaign.refund();
        vm.expectRevert(CrowdFund.NothingToRefund.selector);
        campaign.refund();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function test_TimeRemaining() public {
        assertEq(campaign.timeRemaining(), 7 days);
        vm.warp(block.timestamp + 1 days);
        assertEq(campaign.timeRemaining(), 6 days);
        vm.warp(DEADLINE + 100);
        assertEq(campaign.timeRemaining(), 0);
    }

    function test_GoalReached_Toggles() public {
        assertFalse(campaign.goalReached());
        _fundToGoal();
        assertTrue(campaign.goalReached());
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Contribute(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(alice, amount);
        vm.prank(alice);
        campaign.contribute{value: amount}();

        assertEq(campaign.totalRaised(), amount);
        assertEq(campaign.contributions(alice), amount);
    }

    function testFuzz_WithdrawWhenGoalMet(uint96 amount) public {
        amount = uint96(bound(amount, GOAL, type(uint96).max));
        vm.deal(alice, amount);
        vm.prank(alice);
        campaign.contribute{value: amount}();

        uint256 before = creator.balance;
        vm.prank(creator);
        campaign.withdraw();
        assertEq(creator.balance, before + amount);
    }

    function testFuzz_RefundWhenGoalMissed(uint96 amount) public {
        amount = uint96(bound(amount, 1, uint96(GOAL) - 1));
        vm.deal(alice, amount);
        vm.prank(alice);
        campaign.contribute{value: amount}();

        vm.warp(DEADLINE + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        campaign.refund();
        assertEq(alice.balance, before + amount);
        assertEq(address(campaign).balance, 0);
    }

    /// @notice Invariant-style fuzz: with two contributors below goal, both can be
    ///         fully refunded and the contract drains to zero.
    function testFuzz_AllRefundsDrainContract(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1, uint96(GOAL) / 2 - 1));
        b = uint96(bound(b, 1, uint96(GOAL) / 2 - 1));

        vm.deal(alice, a);
        vm.deal(bob, b);
        vm.prank(alice);
        campaign.contribute{value: a}();
        vm.prank(bob);
        campaign.contribute{value: b}();

        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        campaign.refund();
        vm.prank(bob);
        campaign.refund();

        assertEq(address(campaign).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fundToGoal() internal {
        vm.prank(alice);
        campaign.contribute{value: GOAL}();
    }
}

/// @dev Helper contract that rejects all incoming ETH, used to exercise the
///      {CrowdFund.TransferFailed} path.
contract RejectETH {
    receive() external payable {
        revert("no");
    }
}

/// @dev Malicious creator that attempts to re-enter withdraw() during the ETH payout.
contract ReentrantWithdrawCreator {
    CrowdFund internal target;
    bool internal armed;

    function setTarget(CrowdFund _t) external {
        target = _t;
    }

    function arm() external {
        armed = true;
    }

    function withdraw() external {
        target.withdraw();
    }

    receive() external payable {
        if (armed) {
            armed = false;
            target.withdraw(); // nested call should hit the reentrancy guard
        }
    }
}

contract CrowdFundReentrancyGuardTest is Test {
    function test_RevertWhen_WithdrawReentersDuringPayout() public {
        ReentrantWithdrawCreator attacker = new ReentrantWithdrawCreator();
        CrowdFund campaign =
            new CrowdFund(address(attacker), address(0), "Test Campaign", 1 ether, block.timestamp + 1 days);
        attacker.setTarget(campaign);

        address contributor = makeAddr("contributor");
        vm.deal(contributor, 1 ether);
        vm.prank(contributor);
        campaign.contribute{value: 1 ether}();

        attacker.arm();
        vm.expectRevert(CrowdFund.TransferFailed.selector);
        attacker.withdraw();
    }
}
