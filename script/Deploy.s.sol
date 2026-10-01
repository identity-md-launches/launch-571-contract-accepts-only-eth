// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {OneEthCap} from "../src/OneEthCap.sol";

/// @notice Reviewable deployment helper. The IdentityMD launch deploys through ProjectFactory using
/// launch.json, not this script; it exists so the same constructor wiring can be exercised locally
/// and in tests. `deploy` takes its configuration as an argument so tests never touch the
/// environment. `run` reads `BENEFICIARY` from the environment for manual use only.
contract DeployScript is Script {
    function run() external returns (LaunchToken token, OneEthCap cap) {
        address beneficiary = vm.envAddress("BENEFICIARY");
        vm.startBroadcast();
        (token, cap) = deploy(beneficiary);
        vm.stopBroadcast();
    }

    function deploy(address beneficiary) public returns (LaunchToken token, OneEthCap cap) {
        token = new LaunchToken();
        cap = new OneEthCap(beneficiary);
    }
}
