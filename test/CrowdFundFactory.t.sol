// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrowdFundFactory} from "../src/CrowdFundFactory.sol";
import {CrowdFund} from "../src/CrowdFund.sol";

/// @title CrowdFundFactoryTest
/// @notice Unit, edge-case, and fuzz coverage for {CrowdFundFactory}.
contract CrowdFundFactoryTest is Test {
    CrowdFundFactory internal factory;

    address internal creator = makeAddr("creator");
    address internal other = makeAddr("other");

    uint256 internal GOAL = 5 ether;
    uint256 internal DEADLINE;

    event CampaignCreated(
        address indexed creator, address indexed campaign, uint256 goal, uint256 deadline, bytes32 salt
    );

    function setUp() public {
        factory = new CrowdFundFactory();
        DEADLINE = block.timestamp + 3 days;
    }

    /*//////////////////////////////////////////////////////////////
                             CREATE CAMPAIGN
    //////////////////////////////////////////////////////////////*/

    function test_CreateCampaign_DeploysWithCorrectTerms() public {
        vm.prank(creator);
        address addr = factory.createCampaign("Title", GOAL, DEADLINE);

        CrowdFund c = CrowdFund(addr);
        assertEq(c.creator(), creator);
        assertEq(c.title(), "Title");
        assertEq(c.goal(), GOAL);
        assertEq(c.deadline(), DEADLINE);
    }

    function test_CreateCampaign_TracksPerCreator() public {
        vm.startPrank(creator);
        address a = factory.createCampaign("A", GOAL, DEADLINE);
        address b = factory.createCampaign("B", GOAL, DEADLINE);
        vm.stopPrank();

        address[] memory list = factory.getCampaigns(creator);
        assertEq(list.length, 2);
        assertEq(list[0], a);
        assertEq(list[1], b);
        assertEq(factory.getCampaignCount(creator), 2);
    }

    function test_CreateCampaign_SeparatesCreators() public {
        vm.prank(creator);
        address a = factory.createCampaign("A", GOAL, DEADLINE);
        vm.prank(other);
        address b = factory.createCampaign("B", GOAL, DEADLINE);

        assertEq(factory.getCampaigns(creator).length, 1);
        assertEq(factory.getCampaigns(other).length, 1);
        assertEq(factory.getCampaigns(creator)[0], a);
        assertEq(factory.getCampaigns(other)[0], b);
    }

    function test_CreateCampaign_TracksGlobalList() public {
        vm.prank(creator);
        factory.createCampaign("A", GOAL, DEADLINE);
        vm.prank(other);
        factory.createCampaign("B", GOAL, DEADLINE);

        assertEq(factory.totalCampaigns(), 2);
        assertEq(factory.getAllCampaigns().length, 2);
    }

    function test_CreateCampaign_EmitsEvent() public {
        bytes32 expectedSalt = keccak256(abi.encodePacked(creator, uint256(0)));
        address predicted = factory.computeAddress(creator, "Title", GOAL, DEADLINE);

        vm.expectEmit(true, true, false, true);
        emit CampaignCreated(creator, predicted, GOAL, DEADLINE, expectedSalt);
        vm.prank(creator);
        factory.createCampaign("Title", GOAL, DEADLINE);
    }

    function test_CreateCampaign_RevertsZeroGoal() public {
        vm.prank(creator);
        vm.expectRevert(CrowdFundFactory.ZeroGoal.selector);
        factory.createCampaign("Title", 0, DEADLINE);
    }

    function test_CreateCampaign_RevertsDeadlineInPast() public {
        vm.prank(creator);
        vm.expectRevert(CrowdFundFactory.DeadlineInPast.selector);
        factory.createCampaign("Title", GOAL, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                              CREATE2 ADDRESS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeAddress_MatchesDeployment() public {
        address predicted = factory.computeAddress(creator, "Title", GOAL, DEADLINE);
        vm.prank(creator);
        address actual = factory.createCampaign("Title", GOAL, DEADLINE);
        assertEq(actual, predicted);
    }

    function test_ComputeAddress_AdvancesWithNonce() public {
        address predicted0 = factory.computeAddress(creator, "A", GOAL, DEADLINE);
        vm.prank(creator);
        address a = factory.createCampaign("A", GOAL, DEADLINE);
        assertEq(a, predicted0);

        // After one deployment the next predicted address must change.
        address predicted1 = factory.computeAddress(creator, "B", GOAL, DEADLINE);
        assertTrue(predicted1 != predicted0);
        vm.prank(creator);
        address b = factory.createCampaign("B", GOAL, DEADLINE);
        assertEq(b, predicted1);
    }

    function test_CreateCampaign_FunctionalEndToEnd() public {
        // Deploy via factory, fund to goal, withdraw — proves the deployed
        // instance behaves like a standalone CrowdFund.
        vm.prank(creator);
        address addr = factory.createCampaign("Title", GOAL, DEADLINE);
        CrowdFund c = CrowdFund(addr);

        address backer = makeAddr("backer");
        vm.deal(backer, 10 ether);
        vm.prank(backer);
        c.contribute{value: GOAL}();

        vm.prank(creator);
        c.withdraw();
        assertEq(creator.balance, GOAL);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CreateCampaign(uint256 goal, uint256 offset, uint8 count) public {
        goal = bound(goal, 1, type(uint128).max);
        offset = bound(offset, 1, 365 days);
        uint256 n = uint256(count) % 5 + 1; // 1..5 campaigns
        uint256 deadline = block.timestamp + offset;

        vm.startPrank(creator);
        for (uint256 i = 0; i < n; i++) {
            address predicted = factory.computeAddress(creator, "T", goal, deadline);
            address addr = factory.createCampaign("T", goal, deadline);
            assertEq(addr, predicted);
        }
        vm.stopPrank();

        assertEq(factory.getCampaignCount(creator), n);
    }
}
