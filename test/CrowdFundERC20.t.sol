// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrowdFund} from "../src/CrowdFund.sol";
import {CrowdFundFactory} from "../src/CrowdFundFactory.sol";
import {MockERC20, FeeOnTransferERC20, ReturnsFalseERC20} from "./mocks/MockERC20.sol";

/// @title CrowdFundERC20Test
/// @notice ERC20-mode coverage for {CrowdFund} and the ERC20 overloads of
///         {CrowdFundFactory}. Mirrors the ETH suite's behaviour for token campaigns and
///         adds token-specific edge cases (fee-on-transfer accounting, non-compliant
///         tokens, and mode-mismatch guards).
contract CrowdFundERC20Test is Test {
    CrowdFund internal campaign;
    MockERC20 internal token;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    string internal constant TITLE = "Token Campaign";
    uint256 internal constant GOAL = 10 ether; // 10 tokens (18 decimals)
    uint256 internal DEADLINE;

    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);
    event Withdrawn(address indexed creator, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);

    function setUp() public {
        DEADLINE = block.timestamp + 7 days;
        token = new MockERC20();
        campaign = new CrowdFund(creator, address(token), TITLE, GOAL, DEADLINE);

        // Fund and approve the two backers.
        token.mint(alice, 100 ether);
        token.mint(bob, 100 ether);
        vm.prank(alice);
        token.approve(address(campaign), type(uint256).max);
        vm.prank(bob);
        token.approve(address(campaign), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsTokenAndMode() public view {
        assertEq(campaign.token(), address(token));
        assertTrue(campaign.isERC20());
        assertEq(campaign.goal(), GOAL);
    }

    function test_ZeroToken_IsEthMode() public {
        CrowdFund eth = new CrowdFund(creator, address(0), TITLE, GOAL, DEADLINE);
        assertEq(eth.token(), address(0));
        assertFalse(eth.isERC20());
    }

    function test_Constructor_RevertsInvalidToken_OnEOA() public {
        // A non-zero token with no code (an EOA) is rejected so the campaign can't brick.
        address eoa = makeAddr("notAToken");
        vm.expectRevert(CrowdFund.InvalidToken.selector);
        new CrowdFund(creator, eoa, TITLE, GOAL, DEADLINE);
    }

    /*//////////////////////////////////////////////////////////////
                               CONTRIBUTE
    //////////////////////////////////////////////////////////////*/

    function test_Contribute_Token_UpdatesState() public {
        vm.prank(alice);
        campaign.contribute(1 ether);

        assertEq(campaign.totalRaised(), 1 ether);
        assertEq(campaign.contributions(alice), 1 ether);
        assertEq(token.balanceOf(address(campaign)), 1 ether);
        assertEq(token.balanceOf(alice), 99 ether);
    }

    function test_Contribute_Token_Accumulates() public {
        vm.startPrank(alice);
        campaign.contribute(1 ether);
        campaign.contribute(2 ether);
        vm.stopPrank();

        assertEq(campaign.contributions(alice), 3 ether);
        assertEq(campaign.totalRaised(), 3 ether);
    }

    function test_Contribute_Token_MultipleContributors() public {
        vm.prank(alice);
        campaign.contribute(4 ether);
        vm.prank(bob);
        campaign.contribute(6 ether);

        assertEq(campaign.totalRaised(), 10 ether);
        assertEq(campaign.contributions(alice), 4 ether);
        assertEq(campaign.contributions(bob), 6 ether);
        assertTrue(campaign.goalReached());
    }

    function test_Contribute_Token_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Contributed(alice, 1 ether, 1 ether);
        vm.prank(alice);
        campaign.contribute(1 ether);
    }

    function test_Contribute_Token_RevertsZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(CrowdFund.ZeroContribution.selector);
        campaign.contribute(0);
    }

    function test_Contribute_Token_RevertsAfterDeadline() public {
        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(CrowdFund.CampaignEnded.selector);
        campaign.contribute(1 ether);
    }

    function test_Contribute_Token_AllowedExactlyAtDeadline() public {
        vm.warp(DEADLINE); // boundary: still active (<=).
        vm.prank(alice);
        campaign.contribute(1 ether);
        assertEq(campaign.totalRaised(), 1 ether);
    }

    function test_Contribute_Token_RevertsWithoutApproval() public {
        // carol has tokens but never approved the campaign.
        address carol = makeAddr("carol");
        token.mint(carol, 5 ether);
        vm.prank(carol);
        vm.expectRevert(); // transferFrom reverts on missing allowance.
        campaign.contribute(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            MODE MISMATCH GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_ContributeETH_RevertsOnTokenCampaign() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(CrowdFund.NotEthCampaign.selector);
        campaign.contribute{value: 1 ether}();
    }

    function test_ContributeToken_RevertsOnEthCampaign() public {
        CrowdFund eth = new CrowdFund(creator, address(0), TITLE, GOAL, DEADLINE);
        vm.prank(alice);
        vm.expectRevert(CrowdFund.NotTokenCampaign.selector);
        eth.contribute(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_Token_TransfersToCreator() public {
        _fundToGoal();

        vm.prank(creator);
        campaign.withdraw();

        assertEq(token.balanceOf(creator), GOAL);
        assertEq(token.balanceOf(address(campaign)), 0);
        assertTrue(campaign.withdrawn());
    }

    function test_Withdraw_Token_WorksWhenOverfunded() public {
        vm.prank(alice);
        campaign.contribute(15 ether);

        vm.prank(creator);
        campaign.withdraw();
        assertEq(token.balanceOf(creator), 15 ether);
    }

    function test_Withdraw_Token_EmitsEvent() public {
        _fundToGoal();
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(creator, GOAL);
        vm.prank(creator);
        campaign.withdraw();
    }

    function test_Withdraw_Token_RevertsNotCreator() public {
        _fundToGoal();
        vm.prank(alice);
        vm.expectRevert(CrowdFund.NotCreator.selector);
        campaign.withdraw();
    }

    function test_Withdraw_Token_RevertsGoalNotReached() public {
        vm.prank(alice);
        campaign.contribute(1 ether);
        vm.prank(creator);
        vm.expectRevert(CrowdFund.GoalNotReached.selector);
        campaign.withdraw();
    }

    function test_Withdraw_Token_RevertsDoubleWithdraw() public {
        _fundToGoal();
        vm.startPrank(creator);
        campaign.withdraw();
        vm.expectRevert(CrowdFund.AlreadyWithdrawn.selector);
        campaign.withdraw();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 REFUND
    //////////////////////////////////////////////////////////////*/

    function test_Refund_Token_ReturnsContribution() public {
        vm.prank(alice);
        campaign.contribute(3 ether);
        vm.prank(bob);
        campaign.contribute(2 ether);

        vm.warp(DEADLINE + 1);

        vm.prank(alice);
        campaign.refund();

        assertEq(token.balanceOf(alice), 100 ether); // fully restored
        assertEq(campaign.contributions(alice), 0);
        // Bob's share remains escrowed.
        assertEq(token.balanceOf(address(campaign)), 2 ether);
    }

    function test_Refund_Token_EmitsEvent() public {
        vm.prank(alice);
        campaign.contribute(3 ether);
        vm.warp(DEADLINE + 1);

        vm.expectEmit(true, false, false, true);
        emit Refunded(alice, 3 ether);
        vm.prank(alice);
        campaign.refund();
    }

    function test_Refund_Token_RevertsBeforeDeadline() public {
        vm.prank(alice);
        campaign.contribute(3 ether);
        vm.prank(alice);
        vm.expectRevert(CrowdFund.CampaignNotEnded.selector);
        campaign.refund();
    }

    function test_Refund_Token_RevertsWhenGoalReached() public {
        _fundToGoal();
        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(CrowdFund.GoalReached.selector);
        campaign.refund();
    }

    function test_Refund_Token_RevertsNothingToRefund() public {
        vm.warp(DEADLINE + 1);
        vm.prank(bob);
        vm.expectRevert(CrowdFund.NothingToRefund.selector);
        campaign.refund();
    }

    function test_Refund_Token_RevertsDoubleRefund() public {
        vm.prank(alice);
        campaign.contribute(3 ether);
        vm.warp(DEADLINE + 1);
        vm.startPrank(alice);
        campaign.refund();
        vm.expectRevert(CrowdFund.NothingToRefund.selector);
        campaign.refund();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          NON-STANDARD TOKENS
    //////////////////////////////////////////////////////////////*/

    function test_FeeOnTransfer_CreditsReceivedAmount() public {
        // 1% fee token: contributing 10 credits only 9.9.
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20(100); // 1%
        CrowdFund c = new CrowdFund(creator, address(feeToken), TITLE, GOAL, DEADLINE);

        feeToken.mint(alice, 100 ether);
        vm.startPrank(alice);
        feeToken.approve(address(c), type(uint256).max);
        c.contribute(10 ether);
        vm.stopPrank();

        // Only the net amount actually received is credited.
        assertEq(c.totalRaised(), 9.9 ether);
        assertEq(c.contributions(alice), 9.9 ether);
        assertEq(feeToken.balanceOf(address(c)), 9.9 ether);
    }

    function test_ReturnsFalseToken_RevertsTokenTransferFailed() public {
        ReturnsFalseERC20 badToken = new ReturnsFalseERC20();
        CrowdFund c = new CrowdFund(creator, address(badToken), TITLE, GOAL, DEADLINE);

        badToken.mint(alice, 100 ether);
        vm.startPrank(alice);
        badToken.approve(address(c), type(uint256).max);
        vm.expectRevert(CrowdFund.TokenTransferFailed.selector);
        c.contribute(1 ether);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              FACTORY (ERC20)
    //////////////////////////////////////////////////////////////*/

    function test_Factory_CreateERC20Campaign_DeploysWithToken() public {
        CrowdFundFactory factory = new CrowdFundFactory();
        vm.prank(creator);
        address addr = factory.createCampaign(address(token), TITLE, GOAL, DEADLINE);

        CrowdFund c = CrowdFund(addr);
        assertEq(c.creator(), creator);
        assertEq(c.token(), address(token));
        assertTrue(c.isERC20());
        assertEq(c.goal(), GOAL);
    }

    function test_Factory_CreateCampaignERC20_DeploysWithToken() public {
        CrowdFundFactory factory = new CrowdFundFactory();
        vm.prank(creator);
        address addr = factory.createCampaignERC20(TITLE, GOAL, DEADLINE, address(token));

        CrowdFund c = CrowdFund(addr);
        assertEq(c.creator(), creator);
        assertEq(c.token(), address(token));
        assertTrue(c.isERC20());
        assertEq(c.goal(), GOAL);
    }

    function test_Factory_CreateCampaignERC20_RevertsZeroToken() public {
        CrowdFundFactory factory = new CrowdFundFactory();
        vm.prank(creator);
        vm.expectRevert(CrowdFund.TokenNotSupported.selector);
        factory.createCampaignERC20(TITLE, GOAL, DEADLINE, address(0));
    }

    function test_Factory_CreateCampaignERC20_FunctionalEndToEnd() public {
        CrowdFundFactory factory = new CrowdFundFactory();
        vm.prank(creator);
        address addr = factory.createCampaignERC20(TITLE, GOAL, DEADLINE, address(token));
        CrowdFund c = CrowdFund(addr);

        vm.startPrank(alice);
        token.approve(addr, type(uint256).max);
        c.contribute(GOAL);
        vm.stopPrank();

        vm.prank(creator);
        c.withdraw();
        assertEq(token.balanceOf(creator), GOAL);
    }

    function test_Factory_ComputeAddress_ERC20_MatchesDeployment() public {
        CrowdFundFactory factory = new CrowdFundFactory();
        address predicted = factory.computeAddress(creator, address(token), TITLE, GOAL, DEADLINE);
        vm.prank(creator);
        address actual = factory.createCampaign(address(token), TITLE, GOAL, DEADLINE);
        assertEq(actual, predicted);
    }

    function test_Factory_EthAndErc20_ShareNonce() public {
        // An ETH campaign and an ERC20 campaign from the same creator occupy distinct
        // sequential addresses, proving the shared salt scheme works across overloads.
        CrowdFundFactory factory = new CrowdFundFactory();
        vm.startPrank(creator);
        address a = factory.createCampaign(TITLE, GOAL, DEADLINE); // ETH
        address b = factory.createCampaign(address(token), TITLE, GOAL, DEADLINE); // ERC20
        vm.stopPrank();

        assertTrue(a != b);
        assertEq(factory.getCampaignCount(creator), 2);
        assertFalse(CrowdFund(a).isERC20());
        assertTrue(CrowdFund(b).isERC20());
    }

    function test_Factory_ERC20_FunctionalEndToEnd() public {
        CrowdFundFactory factory = new CrowdFundFactory();
        vm.prank(creator);
        address addr = factory.createCampaign(address(token), TITLE, GOAL, DEADLINE);
        CrowdFund c = CrowdFund(addr);

        vm.startPrank(alice);
        token.approve(addr, type(uint256).max);
        c.contribute(GOAL);
        vm.stopPrank();

        vm.prank(creator);
        c.withdraw();
        assertEq(token.balanceOf(creator), GOAL);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Contribute_Token(uint96 amount) public {
        vm.assume(amount > 0);
        token.mint(alice, amount);
        vm.prank(alice);
        campaign.contribute(amount);

        // alice started with 100 ether minted in setUp.
        assertEq(campaign.totalRaised(), amount);
        assertEq(campaign.contributions(alice), amount);
        assertEq(token.balanceOf(address(campaign)), amount);
    }

    function testFuzz_RefundWhenGoalMissed_Token(uint96 amount) public {
        amount = uint96(bound(amount, 1, uint96(GOAL) - 1));
        vm.prank(alice);
        campaign.contribute(amount);

        vm.warp(DEADLINE + 1);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        campaign.refund();
        assertEq(token.balanceOf(alice), before + amount);
        assertEq(token.balanceOf(address(campaign)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fundToGoal() internal {
        vm.prank(alice);
        campaign.contribute(GOAL);
    }
}
