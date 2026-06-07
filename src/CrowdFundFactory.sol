// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrowdFund} from "./CrowdFund.sol";

/// @title CrowdFundFactory
/// @author crowdfund-dapp
/// @notice Deterministically deploys {CrowdFund} campaigns with CREATE2 and indexes
///         them by creator so front-ends can enumerate a user's campaigns cheaply.
/// @dev    Using CREATE2 lets clients precompute a campaign's address before it is
///         deployed via {computeAddress}. The salt is derived from the creator and
///         their current campaign count, guaranteeing a unique address per campaign.
///
///         Campaigns may be denominated in native ETH or a single ERC20 token. The
///         token-less overloads of {createCampaign} and {computeAddress} produce ETH
///         campaigns; the token-bearing overloads pass the token through to the
///         {CrowdFund} constructor. A zero token address is equivalent to ETH mode.
contract CrowdFundFactory {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the funding goal is zero.
    error ZeroGoal();
    /// @notice Thrown when the deadline is not strictly in the future.
    error DeadlineInPast();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new campaign is deployed.
    /// @param creator  The campaign creator (indexer key).
    /// @param campaign The address of the freshly deployed {CrowdFund}.
    /// @param goal     Funding target in the campaign's unit.
    /// @param deadline Unix timestamp after which contributions close.
    /// @param salt     The CREATE2 salt used, for off-chain address reconstruction.
    /// @dev    The campaign's denomination (ETH vs ERC20) is not part of this event; read
    ///         {CrowdFund.token} on the deployed `campaign` to determine it.
    event CampaignCreated(
        address indexed creator, address indexed campaign, uint256 goal, uint256 deadline, bytes32 salt
    );

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice All campaigns deployed by a given creator, in creation order.
    mapping(address => address[]) private _campaignsByCreator;

    /// @notice Flat list of every campaign deployed by this factory.
    address[] private _allCampaigns;

    /*//////////////////////////////////////////////////////////////
                            MUTATIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a new ETH-denominated crowdfunding campaign owned by the caller.
    /// @param title    Human-readable campaign title.
    /// @param goal     Funding target in wei. Must be non-zero.
    /// @param deadline Unix timestamp strictly in the future.
    /// @return campaign The address of the deployed {CrowdFund} instance.
    function createCampaign(string calldata title, uint256 goal, uint256 deadline)
        external
        returns (address campaign)
    {
        return _createCampaign(address(0), title, goal, deadline);
    }

    /// @notice Deploy a new crowdfunding campaign owned by the caller, denominated in `token`.
    /// @dev    Passing `address(0)` for `token` produces an ETH campaign, identical to the
    ///         token-less overload.
    /// @param token    The ERC20 token to denominate the campaign in, or `address(0)` for ETH.
    /// @param title    Human-readable campaign title.
    /// @param goal     Funding target in the token's base units. Must be non-zero.
    /// @param deadline Unix timestamp strictly in the future.
    /// @return campaign The address of the deployed {CrowdFund} instance.
    function createCampaign(address token, string calldata title, uint256 goal, uint256 deadline)
        external
        returns (address campaign)
    {
        return _createCampaign(token, title, goal, deadline);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice List every campaign created by `creator`, in creation order.
    /// @param creator The address to query.
    /// @return The creator's campaign addresses.
    function getCampaigns(address creator) external view returns (address[] memory) {
        return _campaignsByCreator[creator];
    }

    /// @notice Number of campaigns created by `creator`.
    /// @param creator The address to query.
    /// @return The count.
    function getCampaignCount(address creator) external view returns (uint256) {
        return _campaignsByCreator[creator].length;
    }

    /// @notice List every campaign ever deployed by this factory.
    /// @return All campaign addresses.
    function getAllCampaigns() external view returns (address[] memory) {
        return _allCampaigns;
    }

    /// @notice Total number of campaigns deployed by this factory.
    /// @return The count.
    function totalCampaigns() external view returns (uint256) {
        return _allCampaigns.length;
    }

    /// @notice Predict the address of the `creator`'s next ETH campaign deployment.
    /// @param creator  The future campaign creator.
    /// @param title    The title that will be passed to {createCampaign}.
    /// @param goal     The goal that will be passed to {createCampaign}.
    /// @param deadline The deadline that will be passed to {createCampaign}.
    /// @return The deterministic address the next campaign would occupy.
    function computeAddress(address creator, string calldata title, uint256 goal, uint256 deadline)
        external
        view
        returns (address)
    {
        return _computeAddress(creator, address(0), title, goal, deadline);
    }

    /// @notice Predict the address of the `creator`'s next campaign deployment for `token`.
    /// @dev    Uses the same salt scheme as {createCampaign}. Because the salt depends on
    ///         the creator's current campaign count, this reflects the very next
    ///         deployment by that creator regardless of denomination.
    /// @param creator  The future campaign creator.
    /// @param token    The token that will be passed to {createCampaign}, or `address(0)`.
    /// @param title    The title that will be passed to {createCampaign}.
    /// @param goal     The goal that will be passed to {createCampaign}.
    /// @param deadline The deadline that will be passed to {createCampaign}.
    /// @return The deterministic address the next campaign would occupy.
    function computeAddress(address creator, address token, string calldata title, uint256 goal, uint256 deadline)
        external
        view
        returns (address)
    {
        return _computeAddress(creator, token, title, goal, deadline);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Shared deployment + indexing logic for both {createCampaign} overloads.
    function _createCampaign(address token, string calldata title, uint256 goal, uint256 deadline)
        private
        returns (address campaign)
    {
        // Validate here too so we fail cheaply before paying for deployment.
        if (goal == 0) revert ZeroGoal();
        if (deadline <= block.timestamp) revert DeadlineInPast();

        bytes32 salt = _saltFor(msg.sender, _campaignsByCreator[msg.sender].length);
        campaign = address(new CrowdFund{salt: salt}(msg.sender, token, title, goal, deadline));

        _campaignsByCreator[msg.sender].push(campaign);
        _allCampaigns.push(campaign);

        emit CampaignCreated(msg.sender, campaign, goal, deadline, salt);
    }

    /// @dev Shared CREATE2 prediction logic for both {computeAddress} overloads.
    function _computeAddress(address creator, address token, string calldata title, uint256 goal, uint256 deadline)
        private
        view
        returns (address)
    {
        bytes32 salt = _saltFor(creator, _campaignsByCreator[creator].length);
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(CrowdFund).creationCode, abi.encode(creator, token, title, goal, deadline)));
        return _create2Address(salt, initCodeHash);
    }

    /// @dev Deterministic salt bound to a creator and their campaign index.
    function _saltFor(address creator, uint256 index) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(creator, index));
    }

    /// @dev Standard CREATE2 address derivation for this factory as deployer.
    function _create2Address(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
