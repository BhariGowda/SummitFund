// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {EverestOrBust} from "../src/EverestOrBust.sol";

/// @title DeployEverestOrBust
/// @notice Deploys the EverestOrBust fundraise campaign.
/// @dev    Campaign parameters:
///         - Goal:     $69,000 (69_000e18 normalized)
///         - Duration: 69 days (Jan 1 – Mar 10 2027)
///         - Tokens:   USDC, USDT, DAI
///         - Cap:      $69 per address
///
///         Ethereum Mainnet:
///           forge script script/DeployEverestOrBust.s.sol \
///             --rpc-url mainnet --broadcast --verify
///
///         Ethereum Mainnet:
///           forge script script/DeployEverestOrBust.s.sol \
///             --rpc-url mainnet --broadcast --verify
///
///         Required env vars:
///           PRIVATE_KEY, ETHERSCAN_API_KEY
///           USDC_ADDRESS, USDT_ADDRESS, DAI_ADDRESS
contract DeployEverestOrBust is Script {
    /// @dev Jan 1 2027 00:00:00 UTC
    uint256 constant START = 1767225600;

    function run() external returns (EverestOrBust campaign) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address usdt = vm.envAddress("USDT_ADDRESS");
        address dai  = vm.envAddress("DAI_ADDRESS");

        vm.startBroadcast();

        campaign = new EverestOrBust(msg.sender, usdc, usdt, dai, START);

        console2.log("EverestOrBust deployed at:", address(campaign));
        console2.log("Creator:  ", msg.sender);
        console2.log("USDC:     ", usdc);
        console2.log("USDT:     ", usdt);
        console2.log("DAI:      ", dai);
        console2.log("Start:    ", START);
        console2.log("Deadline: ", START + 69 days);
        console2.log("Goal:     $69,000");
        console2.log("Cap:      $69 per address");

        vm.stopBroadcast();
    }
}
