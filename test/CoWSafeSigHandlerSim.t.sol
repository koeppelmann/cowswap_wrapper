// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSafeSigHandlerSim} from "../src/CoWSafeSigHandlerSim.sol";

contract MockWrapper {
    mapping(address => mapping(bytes32 => bool)) public blessed;
    function bless(address safe, bytes32 digest, bool v) external { blessed[safe][digest] = v; }
    function isBlessed(address safe, bytes32 digest) external view returns (bool) { return blessed[safe][digest]; }
}

/// Unit tests for the simulation-only validity branch. The handler reads the original caller from
/// the 20 bytes a Safe >=1.3.0 fallback appends to calldata (HandlerContext) and treats msg.sender
/// as the Safe — so we call it raw, acting as the Safe, with the caller suffix appended.
contract CoWSafeSigHandlerSimTest is Test {
    address constant SETTLEMENT = address(0x5e771e);
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant FAIL = 0xffffffff;

    MockWrapper wrapper;
    CoWSafeSigHandlerSim handler;
    bytes32 digest = keccak256("order");

    function setUp() public {
        wrapper = new MockWrapper();
        handler = new CoWSafeSigHandlerSim(address(wrapper), SETTLEMENT);
    }

    /// raw isValidSignature(bytes32,bytes) call with HandlerContext caller suffix; msg.sender = this test
    /// contract (plays the Safe).
    function _call1271(address caller, bytes32 hash) internal view returns (bool ok, bytes4 ret) {
        bytes memory cd = abi.encodePacked(
            abi.encodeWithSignature("isValidSignature(bytes32,bytes)", hash, bytes("")), caller
        );
        (bool success, bytes memory r) = address(handler).staticcall(cd);
        return (success, success && r.length >= 4 ? bytes4(r) : bytes4(0));
    }

    function test_gasprice0_settlementCaller_isValid_withoutBless() public {
        vm.txGasPrice(0); // foundry default, explicit for clarity
        (bool ok, bytes4 ret) = _call1271(SETTLEMENT, digest);
        assertTrue(ok);
        assertEq(ret, MAGIC, "simulation (gasprice 0) must validate without bless");
    }

    function test_gaspriceNonzero_settlementCaller_requiresBless() public {
        vm.txGasPrice(1); // any real tx
        (bool ok, bytes4 ret) = _call1271(SETTLEMENT, digest);
        assertTrue(ok);
        assertEq(ret, FAIL, "on-chain (gasprice > 0) unblessed must FAIL");

        wrapper.bless(address(this), digest, true);
        (ok, ret) = _call1271(SETTLEMENT, digest);
        assertTrue(ok);
        assertEq(ret, MAGIC, "on-chain blessed must validate");
    }

    function test_gasprice0_doesNotAffect_nonSettlementCaller() public {
        vm.txGasPrice(0);
        // non-settlement caller goes down the standard Safe path, which calls signedMessages()
        // on msg.sender (this test contract) — no such function, so the call must revert/fail,
        // proving gasprice==0 grants nothing outside the CoW path.
        (bool ok,) = _call1271(address(0xbeef), digest);
        assertFalse(ok, "gasprice 0 must not validate for non-settlement callers");
    }

    function test_legacyPath_settlementCaller_deniedEvenAtGasprice0() public {
        vm.txGasPrice(0);
        bytes memory cd = abi.encodePacked(
            abi.encodeWithSignature("isValidSignature(bytes,bytes)", bytes("data"), bytes("")), SETTLEMENT
        );
        (bool success, bytes memory r) = address(handler).staticcall(cd);
        assertTrue(success);
        assertEq(bytes4(r), bytes4(0), "legacy path stays denied for the settlement caller");
    }
}
