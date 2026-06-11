// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CrowdFund} from "../../src/CrowdFund.sol";

/// @title CrowdFundHandler
/// @notice Bounded action surface for the {CrowdFund} invariant suite. The invariant
///         fuzzer drives a single ETH campaign through random sequences of contribute /
///         withdraw / refund / time-warp actions across a small fixed actor set. Every
///         action swallows reverts so the handler itself never reverts, and ghost
///         accounting is updated only on the successful path.
contract CrowdFundHandler is Test {
    CrowdFund public immutable campaign;
    address public immutable creator;

    /// @dev Fixed actor set keeps state enumerable for the sum-of-contributions invariant.
    address[3] public actors;

    /// @notice Cumulative ETH the creator has actually pulled via {CrowdFund.withdraw}.
    uint256 public totalWithdrawn;

    constructor(CrowdFund _campaign, address _creator) {
        campaign = _campaign;
        creator = _creator;
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
    }

    /// @dev Contribute a bounded amount from a pseudo-random actor while funding is open.
    function contribute(uint256 actorSeed, uint256 amount) external {
        if (block.timestamp > campaign.deadline()) return;
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 50 ether);
        vm.deal(actor, amount);
        vm.prank(actor);
        try campaign.contribute{value: amount}() {} catch {}
    }

    /// @dev Attempt a creator withdrawal; credit the ghost only when it succeeds.
    function withdraw() external {
        uint256 balanceBefore = address(campaign).balance;
        vm.prank(creator);
        try campaign.withdraw() {
            totalWithdrawn += balanceBefore;
        } catch {}
    }

    /// @dev Attempt a refund for a pseudo-random actor.
    function refund(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try campaign.refund() {} catch {}
    }

    /// @dev Jump time strictly past the deadline to unlock the refund / failed-campaign paths.
    function warpPastDeadline() external {
        vm.warp(campaign.deadline() + 1);
    }

    /// @notice Sum of every tracked actor's remaining (un-refunded) contribution.
    /// @return total The aggregate of `contributions[actor]` over the actor set.
    function sumContributions() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += campaign.contributions(actors[i]);
        }
    }

    /// @notice The amount the creator could withdraw right now.
    /// @return The escrow balance when the goal is met and unclaimed, otherwise zero.
    function withdrawableNow() external view returns (uint256) {
        if (campaign.totalRaised() >= campaign.goal() && !campaign.withdrawn()) {
            return address(campaign).balance;
        }
        return 0;
    }
}

/// @title CrowdFundInvariants
/// @notice Stateful invariant suite for {CrowdFund} in ETH mode. Asserts the escrow's
///         conservation guarantees hold across every reachable contribute/withdraw/refund
///         interleaving the handler can produce.
contract CrowdFundInvariants is StdInvariant, Test {
    CrowdFund internal campaign;
    CrowdFundHandler internal handler;

    address internal creator = makeAddr("creator");
    uint256 internal constant GOAL = 100 ether;

    function setUp() public {
        uint256 deadline = block.timestamp + 30 days;
        campaign = new CrowdFund(creator, address(0), "Invariant Campaign", GOAL, deadline);

        handler = new CrowdFundHandler(campaign, creator);

        // Drive only the handler, and only through its curated action set.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = CrowdFundHandler.contribute.selector;
        selectors[1] = CrowdFundHandler.withdraw.selector;
        selectors[2] = CrowdFundHandler.refund.selector;
        selectors[3] = CrowdFundHandler.warpPastDeadline.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Total contributed always covers whatever is withdrawable: the creator can
    ///         never be entitled to more than backers actually put in.
    function invariant_totalContributedCoversWithdrawable() public view {
        assertGe(campaign.totalRaised(), handler.withdrawableNow());
    }

    /// @notice After the deadline with the goal unmet, the entire remaining escrow is exactly
    ///         the sum of outstanding contributions — every wei is refundable, none stranded.
    function invariant_failedCampaignIsFullyRefundable() public view {
        if (block.timestamp > campaign.deadline() && campaign.totalRaised() < GOAL) {
            assertEq(handler.sumContributions(), address(campaign).balance);
        }
    }

    /// @notice The creator can never withdraw more, in aggregate, than was ever raised.
    function invariant_creatorCannotOverWithdraw() public view {
        assertLe(handler.totalWithdrawn(), campaign.totalRaised());
    }
}
