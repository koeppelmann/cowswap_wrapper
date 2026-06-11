// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {CoWSafeSigHandlerSim} from "../src/CoWSafeSigHandlerSim.sol";

/*
 * Deterministic CREATE2 deploy of CoWSafeSigHandlerSim via the Arachnid factory.
 *   PK=<deployer> forge script script/DeploySimHandler.s.sol --rpc-url $RPC --broadcast
 * Use --sig "predict()" (no broadcast) to just print the address.
 */
contract DeploySimHandler is Script {
    address constant FACTORY    = 0x4e59b44847b379578588920cA78FbF26c0B4956C; // Arachnid CREATE2
    address constant WRAPPER    = 0x531636e6e18F3A52c283aCCda39D7185E4597A37; // CoWSafeWrapper (staging)
    address constant SETTLEMENT = 0xf553d092b50bdcbddeD1A99aF2cA29FBE5E2CB13; // Gnosis staging/barn
    bytes32 constant SALT       = bytes32(bytes("CoWSafeSigHandlerSim.v1"));   // ascii, right-padded

    function _initcode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(CoWSafeSigHandlerSim).creationCode, abi.encode(WRAPPER, SETTLEMENT));
    }

    function predict() public pure returns (address) {
        address a = address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), FACTORY, SALT, keccak256(_initcode()))
        ))));
        console2.log("predicted CoWSafeSigHandlerSim:", a);
        return a;
    }

    function run() external {
        address predicted = predict();
        vm.startBroadcast(vm.envUint("PK"));
        (bool ok, bytes memory ret) = FACTORY.call(abi.encodePacked(SALT, _initcode()));
        require(ok, "create2 failed");
        address deployed = address(uint160(bytes20(ret)));
        vm.stopBroadcast();
        console2.log("deployed CoWSafeSigHandlerSim:", deployed);
        require(deployed == predicted, "addr mismatch");
        require(deployed.code.length > 0, "no code");
    }
}
