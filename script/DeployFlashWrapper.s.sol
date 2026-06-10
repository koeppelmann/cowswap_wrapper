// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {CowFlashLoanWrapper, IAavePoolFL} from "../src/CowFlashLoanWrapper.sol";
import {ICowSettlement} from "../src/CowWrapper.sol";

/*
 * Deterministic CREATE2 deploy of CowFlashLoanWrapper (trampoline build) via the Arachnid factory.
 *   PK=<deployer> forge script script/DeployFlashWrapper.s.sol --rpc-url $RPC --broadcast
 * Use --sig "predict()" (no broadcast) to just print the address.
 */
contract DeployFlashWrapper is Script {
    address constant FACTORY    = 0x4e59b44847b379578588920cA78FbF26c0B4956C; // Arachnid CREATE2
    address constant SETTLEMENT = 0xf553d092b50bdcbddeD1A99aF2cA29FBE5E2CB13; // Gnosis staging/barn
    address constant POOL       = 0xb50201558B00496A145fE76f7424749556E326D8; // Aave V3
    bytes32 constant SALT       = bytes32(bytes("CowFlashLoanWrapper.v4"));    // ascii, right-padded

    function _initcode() internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(CowFlashLoanWrapper).creationCode,
            abi.encode(ICowSettlement(SETTLEMENT), IAavePoolFL(POOL))
        );
    }

    function predict() public pure returns (address) {
        address a = address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), FACTORY, SALT, keccak256(_initcode()))
        ))));
        console2.log("salt (ascii CowFlashLoanWrapper.v2):");
        console2.logBytes32(SALT);
        console2.log("predicted CowFlashLoanWrapper:", a);
        return a;
    }

    function run() external {
        address predicted = predict();
        vm.startBroadcast(vm.envUint("PK"));
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(SALT, _initcode()));
        require(ok, "create2 failed");
        address deployed = address(uint160(bytes20(ret)));
        vm.stopBroadcast();
        console2.log("deployed CowFlashLoanWrapper:", deployed);
        require(deployed == predicted, "addr mismatch");
        require(deployed.code.length > 0, "no code");
    }
}
