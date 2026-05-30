// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_Swap} from "@harbor-swap-script/Deploy_Swap.sol";

/// @notice Deploy the full Harbor swap stack (registry + all executors + 1inch) via BaoFactory.
/// @dev Does not deploy HarborYield or minter infrastructure. Run before or independently of
///      the Harbor Yield consumer deploy when the swap stack should exist as shared infrastructure.
///      Usage: script/run-script Deploy_Swap --salt harbor_v1 --network mainnet
contract Deploy_Swap_Script is Deploy_Swap, Script {
    function run(string memory saltPrefix, string memory network) external {
        vm.startBroadcast();
        deploySwapInfrastructure(saltPrefix, network);
        vm.stopBroadcast();
    }
}
