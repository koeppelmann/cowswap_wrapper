// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CowWrapper, ICowSettlement, ICowWrapper} from "./CowWrapper.sol";

/*
 * CowFlashLoanWrapper — a flash-loan layer for CoW wrapper chains, gated on REAL settlement.
 *
 * Placed FIRST in a wrapper chain, it takes an Aave V3 flash loan and runs the REST of the chain
 * (e.g. CoWSafeWrapper → settle) INSIDE the loan window, so downstream pre/post logic and the
 * settlement itself can use the borrowed liquidity; repayment happens when the chain returns.
 *
 *   solver → wrappedSettle(settleData, chain)
 *     _wrap:  snapshot filledAmount(uid) for each declared order
 *             POOL.flashLoan(...)
 *                executeOperation:  deliver loans → _nextMem(...) → … → settle → repay
 *             require filledAmount(uid) STRICTLY INCREASED for every declared order   ← proof of settle
 *
 * SUCCESS ⇒ REAL SETTLEMENT. The wrapper only returns the wrapper magic value if a genuine
 * GPv2Settlement.settle filled every order UID the solver declared in `wrapperData`. Only `settle`
 * can move `filledAmount`, so a fake downstream wrapper (returning the magic value without settling),
 * a pool that skips the callback, or a pool that substitutes the chain all fail this check and revert
 * the whole transaction. This closes the "fake success without settlement" class.
 *
 * It is otherwise STATELESS with NO registry/owner: a loan that can't be repaid simply reverts. It is
 * expected to hold zero balance between transactions; do not send it tokens (there is no recovery).
 *
 * wrapperData = abi.encode(Loan[] loans, bytes[] uids)
 *   loans : which tokens/amounts to flash-borrow and where to deliver them
 *   uids  : the 56-byte CoW order UID(s) that this settlement MUST fill (≥1)
 */

interface IAavePoolFL {
    function flashLoan(
        address receiverAddress, address[] calldata assets, uint256[] calldata amounts,
        uint256[] calldata interestRateModes, address onBehalfOf, bytes calldata params, uint16 referralCode
    ) external;
}
interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
interface ISettlementFilled {
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}

contract CowFlashLoanWrapper is CowWrapper {
    uint256 internal constant MAX_LOANS = 8;

    IAavePoolFL public immutable POOL;

    struct Loan { address token; uint256 amount; address recipient; }
    struct FlashCtx { bytes settleData; bytes remaining; address[] assets; uint256[] amounts; address[] recipients; }

    // transient: 1 while a wrappedSettle-initiated flash loan is in flight
    bytes32 private constant T_FL = keccak256("CowFlashLoanWrapper.FL");

    error NotPool();
    error NotSelfInitiated();
    error NotInWrappedSettle();

    constructor(ICowSettlement settlement_, IAavePoolFL pool_) CowWrapper(settlement_) {
        POOL = pool_;
    }

    /// @inheritdoc ICowWrapper
    function name() external pure override returns (string memory) { return "CowFlashLoanWrapper"; }

    /// @inheritdoc ICowWrapper
    function validateWrapperData(bytes calldata wrapperData) external pure override {
        (Loan[] memory loans, bytes[] memory uids) = abi.decode(wrapperData, (Loan[], bytes[]));
        require(loans.length > 0 && loans.length <= MAX_LOANS, "loans");
        require(uids.length > 0 && uids.length <= MAX_LOANS, "uids");
    }

    /// @inheritdoc CowWrapper
    function _wrap(bytes calldata settleData, bytes calldata wrapperData, bytes calldata remainingWrapperData)
        internal
        override
    {
        require(_tload(T_FL) == 0, "reentrant");
        (Loan[] memory loans, bytes[] memory uids) = abi.decode(wrapperData, (Loan[], bytes[]));
        require(uids.length > 0 && uids.length <= MAX_LOANS, "uids");

        FlashCtx memory c = _buildCtx(settleData, remainingWrapperData, loans);

        // snapshot each declared order's fill BEFORE the loan
        uint256[] memory filledBefore = new uint256[](uids.length);
        for (uint256 j = 0; j < uids.length; j++) {
            filledBefore[j] = ISettlementFilled(address(SETTLEMENT)).filledAmount(uids[j]);
        }

        _tstore(T_FL, 1);
        POOL.flashLoan(
            address(this), c.assets, c.amounts, new uint256[](c.assets.length) /* modes: pure flash */,
            address(this), abi.encode(c), 0
        );
        _tstore(T_FL, 0);

        // PROOF OF SETTLE: only GPv2Settlement.settle can move filledAmount — require every declared
        // order strictly increased, else the whole tx reverts. This is what makes "success" mean "settled".
        for (uint256 j = 0; j < uids.length; j++) {
            require(ISettlementFilled(address(SETTLEMENT)).filledAmount(uids[j]) > filledBefore[j], "no settle");
        }
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
    ///         itself initiated from an in-flight wrappedSettle. All delivery/repayment uses the
    ///         context WE encoded (c.*) — only the per-asset `premiums` come from the pool.
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

        FlashCtx memory c = abi.decode(params, (FlashCtx));
        require(premiums.length == c.assets.length, "len");

        // deliver the borrowed liquidity to each declared recipient
        for (uint256 i = 0; i < c.assets.length; i++) {
            require(IERC20Min(c.assets[i]).transfer(c.recipients[i], c.amounts[i]), "deliver");
        }

        // run the rest of the wrapper chain (→ … → GPv2Settlement.settle) inside the loan window
        _nextMem(c.settleData, c.remaining);

        // repay: the chain must have routed amount+premium back to us; Aave pulls via this allowance.
        for (uint256 i = 0; i < c.assets.length; i++) {
            uint256 due = c.amounts[i] + premiums[i];
            require(IERC20Min(c.assets[i]).balanceOf(address(this)) >= due, "underfunded");
            require(IERC20Min(c.assets[i]).approve(address(POOL), due), "approve");
        }
        return true;
    }

    /// @dev Memory-args mirror of CowWrapper._next (the continuation crosses the Aave callback boundary).
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
