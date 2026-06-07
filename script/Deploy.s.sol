// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CrowdFundFactory} from "../src/CrowdFundFactory.sol";

/// @title Deploy
/// @notice Deploys the {CrowdFundFactory} to Base (or Base Sepolia).
/// @dev    Usage:
///         forge script script/Deploy.s.sol:Deploy \
///             --rpc-url base \
///             --account <keystore-account> \
///             --broadcast \
///             --verify
///
///         Required environment / config:
///         - BASE_RPC_URL (or BASE_SEPOLIA_RPC_URL) in foundry.toml [rpc_endpoints]
///         - BASESCAN_API_KEY for --verify
///
///         Individual campaigns are not deployed here; users create them on-chain
///         by calling {CrowdFundFactory.createCampaign}.
contract Deploy is Script {
    function run() external returns (CrowdFundFactory factory) {
        vm.startBroadcast();

        factory = new CrowdFundFactory();
        console2.log("CrowdFundFactory deployed at:", address(factory));
        console2.log("Chain id:", block.chainid);

        vm.stopBroadcast();
    }
}
