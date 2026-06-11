// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DefaultCallbackHandler} from "safe-contracts/contracts/handler/DefaultCallbackHandler.sol";
import {HandlerContext} from "safe-contracts/contracts/handler/HandlerContext.sol";
import {ISignatureValidator} from "safe-contracts/contracts/interfaces/ISignatureValidator.sol";

/*
 * CoWSafeSigHandlerSim — CoWSafeSigHandler with SIMULATION-ONLY validity for the CoW caller.
 *
 * Identical to CoWSafeSigHandler in every way except ONE added branch on the CoW EIP-1271 path:
 * when `tx.gasprice == 0` (true in eth_call-style simulations, never in a real transaction) the
 * handler returns the magic value without consulting the wrapper's bless state.
 *
 * Why: the orderbook validates EIP-1271 orders at submission (and the autopilot re-validates them
 * continuously) by SIMULATING `isValidSignature` outside any settlement. The strict handler is
 * bless-only, so those simulations fail and bless-gated orders can only be submitted as presign —
 * which, once set, makes the order settleable WITHOUT the wrapper (pre/post bypass if the Safe
 * happens to be funded). This variant lets such orders be submitted as genuine `eip1271`:
 * simulations (gas price 0) see a valid signature; any real transaction has `tx.gasprice > 0`,
 * so ON-CHAIN validity remains bless-only and the enforcement guarantees are unchanged.
 *
 * Trust note: this assumes a real settlement never executes with an effective gas price of zero.
 * On EIP-1559 networks the effective gas price is >= the (nonzero) base fee. A block producer who
 * could craft a 0-gas-price block AND collude with an allowlisted solver could validate an
 * unblessed order on-chain; that is outside this design's threat model (and CoW's own orderbook
 * relies on the same simulation/reality distinction). The proper long-term fix is wrapper-aware
 * validation in the orderbook itself (simulate through the chain declared in appData).
 */

interface ICoWSafeWrapper {
    function isBlessed(address safe, bytes32 digest) external view returns (bool);
}

interface ISafe {
    function checkSignatures(bytes32 dataHash, bytes calldata data, bytes calldata signatures) external view;
    function signedMessages(bytes32 messageHash) external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
}

contract CoWSafeSigHandlerSim is DefaultCallbackHandler, HandlerContext, ISignatureValidator {
    address public immutable WRAPPER;
    // The CoW settlement this handler special-cases (prod vs staging/barn differ) — constructor arg.
    address public immutable SETTLEMENT;

    // keccak256("SafeMessage(bytes message)")
    bytes32 private constant SAFE_MSG_TYPEHASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;
    bytes4 internal constant UPDATED_MAGIC_VALUE = 0x1626ba7e; // EIP-1271 (bytes32) magic
    bytes4 internal constant FAIL = 0xffffffff;

    constructor(address wrapper, address settlement) {
        require(wrapper != address(0) && settlement != address(0), "zero");
        WRAPPER = wrapper;
        SETTLEMENT = settlement;
    }

    // --------- EIP-1271 (bytes32) — the function CoW settlement calls ---------
    function isValidSignature(bytes32 _dataHash, bytes calldata _signature) external view returns (bytes4) {
        address safe = _manager(); // == msg.sender == the Safe forwarding this call
        if (_msgSender() == SETTLEMENT) {
            // Simulation-only validity: orderbook/autopilot simulations run with gas price 0; a real
            // settlement never does. On-chain the bless check below remains the only way to validate.
            if (tx.gasprice == 0) return UPDATED_MAGIC_VALUE;
            // CoW path: enforced-hooks bless only. No fall-through to owner sigs (would bypass pre/post).
            return ICoWSafeWrapper(WRAPPER).isBlessed(safe, _dataHash) ? UPDATED_MAGIC_VALUE : FAIL;
        }
        // Standard path: faithful reproduction of CompatibilityFallbackHandler behaviour.
        bytes memory data = abi.encode(_dataHash);
        bytes32 messageHash = _safeMessageHash(ISafe(safe), data);
        if (_signature.length == 0) {
            if (ISafe(safe).signedMessages(messageHash) == 0) return FAIL;
        } else {
            ISafe(safe).checkSignatures(messageHash, data, _signature); // reverts on invalid
        }
        return UPDATED_MAGIC_VALUE;
    }

    // --------- Legacy isValidSignature(bytes,bytes) — standard behaviour ---------
    function isValidSignature(bytes memory _data, bytes memory _signature) public view override returns (bytes4) {
        // CoW must validate via the bytes32 EIP-1271 path; deny the legacy path for the settlement caller
        // (unchanged from CoWSafeSigHandler — the orderbook and settlement only use the bytes32 variant).
        if (_msgSender() == SETTLEMENT) return bytes4(0);
        address safe = _manager();
        bytes32 messageHash = _safeMessageHash(ISafe(safe), _data);
        if (_signature.length == 0) {
            require(ISafe(safe).signedMessages(messageHash) != 0, "Hash not approved");
        } else {
            ISafe(safe).checkSignatures(messageHash, _data, _signature);
        }
        return EIP1271_MAGIC_VALUE; // 0x20c13b0b
    }

    // --------- message-hash helpers (standard) ---------
    function getMessageHash(bytes memory message) public view returns (bytes32) {
        return _safeMessageHash(ISafe(_manager()), message);
    }
    function getMessageHashForSafe(ISafe safe, bytes memory message) public view returns (bytes32) {
        return _safeMessageHash(safe, message);
    }
    function _safeMessageHash(ISafe safe, bytes memory message) private view returns (bytes32) {
        bytes32 safeMessageHash = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(message)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), safe.domainSeparator(), safeMessageHash));
    }
}
