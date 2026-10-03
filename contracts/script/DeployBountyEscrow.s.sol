// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Script} from "forge-std/Script.sol";
import {BountyEscrow} from "../src/BountyEscrow.sol";
contract DeployBountyEscrow is Script {
    function run() external returns (BountyEscrow escrow) {
        require(block.chainid == 84532, "Base Sepolia only");
        address usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        uint256 key = vm.envUint("ESCROW_ARBITER_PRIVATE_KEY");
        vm.startBroadcast(key);
        escrow = new BountyEscrow(usdc, vm.addr(key));
        vm.stopBroadcast();
    }
}
