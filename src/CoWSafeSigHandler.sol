// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DefaultCallbackHandler} from "safe-contracts/contracts/handler/DefaultCallbackHandler.sol";
import {HandlerContext} from "safe-contracts/contracts/handler/HandlerContext.sol";
import {ISignatureValidator} from "safe-contracts/contracts/interfaces/ISignatureValidator.sol";

/*
 * CoWSafeSigHandler — the Safe fallback handler for CoWSafeWrapper-managed positions.
 *
 * It is a full, standards-compatible Safe fallback handler: it inherits the audited
 * Safe `DefaultCallbackHandler` (ERC-721/1155/777 receivers + ERC-165) and `HandlerContext`
 * (the audited `_msgSender()` that reads the original caller appended by a Safe >=1.3.0
 * fallback), and it reproduces the standard `CompatibilityFallbackHandler` signature surface
 * (`isValidSignature` legacy + EIP-1271, `getMessageHash[ForSafe]`) faithfully.
 *
 * The ONLY behavioural difference vs. the stock handler: when the EIP-1271 query originates
 * from the CoW `SETTLEMENT` (detected via the appended caller), validation is delegated to the
 * wrapper's transient "bless" state instead of to Safe owner signatures. For every other caller
 * the standard Safe owner-signature path runs unchanged — so these remain ordinary, fully
 * compatible Safes for Seaport, Snapshot, WalletConnect, etc.
 *
 * Why we don't `override` CompatibilityFallbackHandler directly: its v1.3.0 `isValidSignature`
 * functions are not declared `virtual`, so they cannot be overridden without forking the audited
 * file. Inheriting `DefaultCallbackHandler` (unmodified) and reproducing the small signature
 * surface keeps the most standard code unmodified while letting us special-case CoW.
 *
 * Security note (the enforcement hinge): on the CoW path we return the magic value ONLY if the
 * order digest is currently blessed by an in-flight `wrappedSettle`. We deliberately do NOT fall
 * back to owner-signature validation for the settlement caller — otherwise an owner-signed order
 * could settle without the wrapper running its pre/post (a bypass). All CoW orders for these Safes
 * must go through the wrapper.
 */

interface ICoWSafeWrapper {
    function isBlessed(address safe, bytes32 digest) external view returns (bool);
}

interface ISafe {
    function checkSignatures(bytes32 dataHash, bytes calldata data, bytes calldata signatures) external view;
    function signedMessages(bytes32 messageHash) external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
}

contract CoWSafeSigHandler is DefaultCallbackHandler, HandlerContext, ISignatureValidator {
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
        // so hook enforcement can never be skipped through an owner-sig fallback here (audit SHOULD-FIX #3).
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
