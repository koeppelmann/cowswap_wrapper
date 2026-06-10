// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CowWrapper, ICowSettlement, ICowWrapper} from "./CowWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * CowFlashLoanWrapper — a flash-loan layer for CoW wrapper chains.
 *
 * Placed FIRST in a wrapper chain, it takes an Aave V3 flash loan and runs the REST of the chain
 * (e.g. CoWSafeWrapper → settle) INSIDE the loan window, so downstream pre/post logic and the
 * settlement itself can use the borrowed liquidity; repayment happens when the chain returns.
 *
 *   solver → wrappedSettle(settleData, chain)
 *     _wrap:  commit keccak256(ctx) to transient storage   ← TRAMPOLINE binding
 *             POOL.flashLoan(...) with ctx as params
 *                executeOperation:  require keccak256(params) == commit   ← reject injected data
 *                                   deliver loans → _nextMem(...) → … → settle → repay
 *
 * TRAMPOLINE / DATA-INTEGRITY (the security hinge). The Aave callback (`executeOperation`) receives
 * its `params` from the pool, which is data that crossed an external-call boundary. We do NOT trust it:
 * before the loan, `_wrap` stores keccak256 of the context (settleData + the rest of the chain + the
 * loan delivery plan) in transient storage; the callback re-hashes the `params` it was handed and
 * requires an exact match. So the settlement can ONLY ever be driven by the bytes the solver passed to
 * `wrappedSettle` — a malicious/upgraded pool cannot substitute the settle calldata or redirect loan
 * delivery. The final hop is additionally constrained to the `settle()` selector (in `_nextMem`). This
 * mirrors CoW's audited FlashLoanRouter (`pendingDataHash`).
 *
 * It is STATELESS with NO registry/owner: a loan that can't be repaid simply reverts. It is expected to
 * hold zero balance between transactions; do not send it tokens (there is no recovery).
 *
 * NOTE: it deliberately does NOT verify that the downstream actually filled an order. Fill-correctness
 * is enforced where it belongs — `CoWSafeWrapper` independently requires `filledAmount >= expectedFill`
 * for the user's order — so this layer stays a generic liquidity primitive.
 *
 * wrapperData = abi.encode(Loan[] loans)   // tokens/amounts to flash-borrow and where to deliver them
 */

interface IAavePoolFL {
    function flashLoan(
        address receiverAddress, address[] calldata assets, uint256[] calldata amounts,
        uint256[] calldata interestRateModes, address onBehalfOf, bytes calldata params, uint16 referralCode
    ) external;
}
// vendored standard implementation: OpenZeppelin v5.5.0 SafeERC20 (USDT-style no-return-data tokens,
// forceApprove for approve-from-nonzero restrictions, empty returndata accepted only from contracts)

contract CowFlashLoanWrapper is CowWrapper {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_LOANS = 8;

    IAavePoolFL public immutable POOL;

    struct Loan { address token; uint256 amount; address recipient; }
    struct FlashCtx { bytes settleData; bytes remaining; address[] assets; uint256[] amounts; address[] recipients; }

    // transient: 1 while a wrappedSettle-initiated flash loan is in flight
    bytes32 private constant T_FL = keccak256("CowFlashLoanWrapper.FL");
    // transient: keccak256 of the FlashCtx params committed by _wrap (the trampoline binding)
    bytes32 private constant T_COMMIT = keccak256("CowFlashLoanWrapper.COMMIT");

    error NotPool();
    error NotSelfInitiated();
    error NotInWrappedSettle();
    error ParamsTampered();

    constructor(ICowSettlement settlement_, IAavePoolFL pool_) CowWrapper(settlement_) {
        POOL = pool_;
    }

    /// @inheritdoc ICowWrapper
    function name() external pure override returns (string memory) { return "CowFlashLoanWrapper"; }

    /// @inheritdoc ICowWrapper
    function validateWrapperData(bytes calldata wrapperData) external pure override {
        Loan[] memory loans = abi.decode(wrapperData, (Loan[]));
        require(loans.length > 0 && loans.length <= MAX_LOANS, "loans");
    }

    /// @inheritdoc CowWrapper
    function _wrap(bytes calldata settleData, bytes calldata wrapperData, bytes calldata remainingWrapperData)
        internal
        override
    {
        require(_tload(T_FL) == 0, "reentrant");
        Loan[] memory loans = abi.decode(wrapperData, (Loan[]));

        FlashCtx memory c = _buildCtx(settleData, remainingWrapperData, loans);

        // TRAMPOLINE: commit the exact context the callback must run with, then start the loan.
        bytes memory params = abi.encode(c);
        _tstore(T_COMMIT, uint256(keccak256(params)));
        _tstore(T_FL, 1);
        POOL.flashLoan(
            address(this), c.assets, c.amounts, new uint256[](c.assets.length) /* modes: pure flash */,
            address(this), params, 0
        );
        _tstore(T_FL, 0);
        _tstore(T_COMMIT, 0);
    }

    function _buildCtx(bytes calldata settleData, bytes calldata remaining, Loan[] memory loans)
        private pure
        returns (FlashCtx memory c)
    {
        uint256 n = loans.length;
        require(n > 0 && n <= MAX_LOANS, "loans");
        c.settleData = settleData;
        c.remaining = remaining;
        c.assets = new address[](n);
        c.amounts = new uint256[](n);
        c.recipients = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            for (uint256 k = 0; k < i; k++) require(loans[k].token != loans[i].token, "dup asset");
            c.assets[i] = loans[i].token;
            c.amounts[i] = loans[i].amount;
            c.recipients[i] = loans[i].recipient;
        }
    }

    /// @notice Aave V3 flash-loan callback. Only callable by the pool, only for loans this wrapper
    ///         itself initiated from an in-flight wrappedSettle, and only with the EXACT params the
    ///         entry point committed (the trampoline check). All delivery/repayment uses that context;
    ///         only the per-asset `premiums` come from the pool.
    function executeOperation(
        address[] calldata /*assets*/,
        uint256[] calldata /*amounts*/,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(POOL), NotPool());
        require(initiator == address(this), NotSelfInitiated());
        require(_tload(T_FL) == 1, NotInWrappedSettle());
        // TRAMPOLINE binding: the only data we will act on is what _wrap committed.
        require(uint256(keccak256(params)) == _tload(T_COMMIT), ParamsTampered());

        FlashCtx memory c = abi.decode(params, (FlashCtx));
        require(premiums.length == c.assets.length, "len");

        // deliver the borrowed liquidity to each committed recipient
        for (uint256 i = 0; i < c.assets.length; i++) {
            IERC20(c.assets[i]).safeTransfer(c.recipients[i], c.amounts[i]);
        }

        // run the rest of the wrapper chain (→ … → GPv2Settlement.settle) inside the loan window
        _nextMem(c.settleData, c.remaining);

        // repay: the chain must have routed amount+premium back to us; Aave pulls via this allowance.
        for (uint256 i = 0; i < c.assets.length; i++) {
            uint256 due = c.amounts[i] + premiums[i];
            require(IERC20(c.assets[i]).balanceOf(address(this)) >= due, "underfunded");
            IERC20(c.assets[i]).forceApprove(address(POOL), due);
        }
        return true;
    }

    /// @dev Memory-args mirror of CowWrapper._next (the continuation crosses the Aave callback boundary).
    ///      The terminal hop is constrained to the settle() selector ("only settle() is allowed").
    function _nextMem(bytes memory settleData, bytes memory remaining) internal {
        if (remaining.length == 0) {
            require(settleData.length >= 4 && bytes4(_first4(settleData)) == ICowSettlement.settle.selector,
                InvalidSettleData(settleData));
            _callWithBubbleRevert(address(SETTLEMENT), settleData);
        } else {
            require(remaining.length >= 20, "chain");
            address nextWrapper = address(bytes20(_first20(remaining)));
            bytes memory rest = _slice(remaining, 20);
            bytes memory returnData = _callWithBubbleRevert(
                nextWrapper, abi.encodeCall(ICowWrapper.wrappedSettle, (settleData, rest))
            );
            require(
                returnData.length == 32 && bytes32(returnData) == bytes32(ICowWrapper.wrappedSettle.selector),
                InvalidNextWrapper(nextWrapper)
            );
        }
    }

    // ---- memory byte helpers ----
    function _first4(bytes memory b) private pure returns (bytes4 out) { assembly { out := mload(add(b, 32)) } }
    function _first20(bytes memory b) private pure returns (bytes20 out) { assembly { out := mload(add(b, 32)) } }
    function _slice(bytes memory b, uint256 start) private pure returns (bytes memory r) {
        uint256 len = b.length - start;
        r = new bytes(len);
        assembly ("memory-safe") { mcopy(add(r, 32), add(add(b, 32), start), len) }
    }

    function _tload(bytes32 slot) private view returns (uint256 v) { assembly { v := tload(slot) } }
    function _tstore(bytes32 slot, uint256 v) private { assembly { tstore(slot, v) } }
}
