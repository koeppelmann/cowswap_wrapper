// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CowWrapper, ICowSettlement, ICowWrapper} from "./CowWrapper.sol";

/*
 * CoWSafeWrapper — a generic CoW Protocol wrapper (ICowWrapper / CowWrapper) that enforces Safe
 * pre/post interactions atomically around a settlement, authorized only by the owning Safe.
 *
 * It is a standard CoW wrapper: it inherits CoW DAO's `CowWrapper` base (solver auth, the
 * `wrappedSettle(bytes settleData, bytes chainedWrapperData)` entry, chained-bundle routing, and the
 * magic-value return) and implements the custom logic in `_wrap`, which calls `_next` to continue the
 * chain to settlement. See contracts/WRAPPER_SPEC.md.
 *
 * Roles: enabled as a Safe MODULE (to run pre/post as the Safe) and must be allowlisted as a CoW
 * solver (so its settle call passes). NOT a Safe fallback handler — that is CoWSafeSigHandler, so
 * `registerMetaOrder` is reachable only by a direct Safe CALL and can't be spoofed via fallback.
 *
 * Per-wrapper data (`wrapperData` in the chain) = abi.encode(Activation[]) — the (safe, nonce)
 * meta-orders this wrapper enforces in the batch. Flow inside `_wrap`:
 *   1. freeze + snapshot the whole batch to memory (so a pre can't mutate a later entry)
 *   2. run every registered `pre` AS the Safe
 *   3. set the transient bless flag (so isValidSignature validates the order) — minimal window
 *   4. _next(settleData, remainingWrapperData)  → eventually GPv2Settlement.settle
 *   5. close the bless window, then require each order fully filled and run its `post` AS the Safe
 * Any failure reverts the whole transaction. Activation is implicit in wrappedSettle (no separate fn).
 */

interface ISafe {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external returns (bool success);
}
interface ISettlementFilled {
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}

contract CoWSafeWrapper is CowWrapper {
    uint256 internal constant MAX_ITEMS = 16;

    struct SafeTx { address to; uint256 value; bytes data; uint8 operation; } // operation: 0 CALL, 1 DELEGATECALL
    /// On-chain we store only the HASHES of pre/post; the actual SafeTxs are supplied at settle time (in
    /// the wrapper data) and checked against these hashes. Cheaper registration; the calldata lives in
    /// the order's appData → wrapper data, forwarded by the solver.
    struct MetaOrder {
        bytes   uid;          // 56-byte CoW order UID = digest(32)++owner(20)++validTo(4)
        uint256 expectedFill; // CoW filledAmount on (full) fill: sellAmount (sell) or buyAmount (buy)
        bytes32 preHash;      // keccak256(abi.encode(to, value, data, operation)) of pre — use hashSafeTx()
        bytes32 postHash;     // keccak256(abi.encode(to, value, data, operation)) of post — use hashSafeTx()
        uint64  notBefore;    // optional earliest exec ts (0 = none)
        uint64  deadline;     // optional latest exec ts   (0 = none)
        uint8   status;       // 0 none · 1 registered · 2 consumed
    }
    mapping(address => mapping(uint256 => MetaOrder)) public metaOrders;

    /// One per order in the batch — supplied by the solver in this wrapper's data
    /// (wrapperData = abi.encode(OrderExec[])). Carries the actual pre/post calldata.
    struct OrderExec { address safe; uint256 nonce; SafeTx pre; SafeTx post; }

    // transient slots (EIP-1153), domain-separated + epoch-scoped
    bytes32 private constant T_EPOCH = keccak256("CoWSafeWrapper.EPOCH");
    bytes32 private constant T_IN    = keccak256("CoWSafeWrapper.IN");

    event Registered(address indexed safe, uint256 indexed nonce, bytes32 uidHash);
    event Cancelled(address indexed safe, uint256 indexed nonce);
    event Settled(address indexed safe, uint256 indexed nonce);

    constructor(ICowSettlement settlement_) CowWrapper(settlement_) {}

    /// @inheritdoc ICowWrapper
    function name() external pure override returns (string memory) { return "CoWSafeWrapper"; }

    // ================= registration (direct Safe CALL only) =================
    /// @notice Register the meta-order for `nonce`. MUST be called by a direct CALL from the Safe
    ///         (an owner-authorized Safe tx). Not reachable via fallback, so msg.sender==safe is safe.
    function registerMetaOrder(uint256 nonce, MetaOrder calldata m) external {
        require(m.uid.length == 56, "uid len");
        require(_uidOwner(m.uid) == msg.sender, "uid owner != safe");
        require(m.expectedFill > 0, "expectedFill");
        MetaOrder storage s = metaOrders[msg.sender][nonce];
        require(s.status != 2, "nonce consumed");
        s.uid = m.uid;
        s.expectedFill = m.expectedFill;
        s.preHash = m.preHash;
        s.postHash = m.postHash;
        s.notBefore = m.notBefore;
        s.deadline = m.deadline;
        s.status = 1;
        emit Registered(msg.sender, nonce, keccak256(m.uid));
    }

    /// @notice Canonical hash of a SafeTx (use this off-chain to compute pre/postHash for registration).
    function hashSafeTx(SafeTx calldata t) external pure returns (bytes32) { return _hashSafeTx(t); }

    /// @notice Cancel an un-consumed registration. Only the Safe, only on status==1.
    function cancelMetaOrder(uint256 nonce) external {
        MetaOrder storage s = metaOrders[msg.sender][nonce];
        require(s.status == 1, "not active");
        s.status = 0;
        emit Cancelled(msg.sender, nonce);
    }

    // ================= ICowWrapper hooks =================
    /// @inheritdoc ICowWrapper
    /// @dev Deterministic, state-independent structural validation of this wrapper's data.
    function validateWrapperData(bytes calldata wrapperData) external view override {
        OrderExec[] memory ex = abi.decode(wrapperData, (OrderExec[]));
        require(ex.length > 0 && ex.length <= MAX_ITEMS, "items");
    }

    /// @inheritdoc CowWrapper
    /// @param wrapperData abi.encode(OrderExec[]) — the orders + their actual pre/post calldata
    function _wrap(bytes calldata settleData, bytes calldata wrapperData, bytes calldata remainingWrapperData)
        internal
        override
    {
        require(_tload(T_IN) == 0, "reentrant"); // no nested wrappedSettle into this wrapper
        // Must be the FINAL wrapper in the chain: the bless window must cover ONLY the direct
        // GPv2Settlement.settle call, never arbitrary downstream wrapper logic. Composition with the
        // generic flash layer still works (FlashLoanWrapper → CoWSafeWrapper → settle, this is final).
        require(remainingWrapperData.length == 0, "must be final wrapper");

        OrderExec[] memory ex = abi.decode(wrapperData, (OrderExec[]));
        uint256 k = ex.length;
        require(k > 0 && k <= MAX_ITEMS, "items");

        uint256 epoch = _tload(T_EPOCH) + 1; // fresh namespace per invocation (no stale bless across calls)
        _tstore(T_EPOCH, epoch);
        _tstore(T_IN, 1);

        ISettlementFilled S = ISettlementFilled(address(SETTLEMENT));
        bytes[]    memory uids    = new bytes[](k);     // snapshot for the post-settle fill check
        uint256[]  memory fills   = new uint256[](k);
        bytes32[]  memory digests = new bytes32[](k);

        // pass 1: verify supplied pre/post against the registered hashes + FREEZE the whole batch
        // (before any pre runs, so a pre can't mutate a later entry; we keep nothing mutable in storage)
        for (uint256 i = 0; i < k; i++) {
            MetaOrder storage m = metaOrders[ex[i].safe][ex[i].nonce];
            require(m.status == 1, "not registered");
            if (m.notBefore != 0) require(block.timestamp >= m.notBefore, "too early");
            if (m.deadline  != 0) require(block.timestamp <= m.deadline,  "expired");
            require(_hashSafeTx(ex[i].pre)  == m.preHash,  "pre mismatch");
            require(_hashSafeTx(ex[i].post) == m.postHash, "post mismatch");
            require(S.filledAmount(m.uid) == 0, "already filled"); // filledBefore == 0
            bytes32 d = _digest(m.uid);
            for (uint256 j = 0; j < i; j++) {
                require(!(digests[j] == d && ex[j].safe == ex[i].safe), "dup digest");
            }
            digests[i] = d;
            uids[i] = m.uid;
            fills[i] = m.expectedFill;
            m.status = 2;   // freeze (one-shot; reverts with the tx on any later failure)
        }

        // pass 2: run every pre AS the Safe, from the (hash-verified) supplied calldata
        for (uint256 i = 0; i < k; i++) _execAsSafe(ex[i].safe, ex[i].pre);

        // pass 3: bless right before continuing to settlement — minimal window
        for (uint256 i = 0; i < k; i++) _tstore(_sBless(epoch, ex[i].safe, digests[i]), 1);

        // continue the wrapper chain → eventually GPv2Settlement.settle (where isValidSignature reads bless)
        _next(settleData, remainingWrapperData);

        _tstore(T_IN, 0); // close the bless window immediately; post txs run UNblessed

        // discharge: require the order filled by AT LEAST expectedFill (with filledBefore==0, proves it
        // settled this tx; for fill-or-kill orders expectedFill is the full amount so this is exact),
        // then run post AS the Safe
        for (uint256 i = 0; i < k; i++) {
            require(S.filledAmount(uids[i]) >= fills[i], "not settled");
            _execAsSafe(ex[i].safe, ex[i].post);
            emit Settled(ex[i].safe, ex[i].nonce);
        }
    }

    // ================= views =================
    function orderStatus(address safe, uint256 nonce) external view returns (uint8) {
        return metaOrders[safe][nonce].status;
    }

    /// @notice EIP-1271 read used by CoWSafeSigHandler. True only during an active wrapped settlement
    ///         and only for a digest blessed this epoch — no stale blessings.
    function isBlessed(address safe, bytes32 digest) external view returns (bool) {
        if (_tload(T_IN) != 1) return false;
        return _tload(_sBless(_tload(T_EPOCH), safe, digest)) == 1;
    }

    // ================= internals =================
    function _execAsSafe(address safe, SafeTx memory t) private {
        require(t.operation <= 1, "op");        // 0 CALL, 1 DELEGATECALL (committed via the SafeTx hash)
        bool ok = ISafe(safe).execTransactionFromModule(t.to, t.value, t.data, t.operation);
        require(ok, "exec failed");
    }

    function _hashSafeTx(SafeTx memory t) private pure returns (bytes32) {
        return keccak256(abi.encode(t.to, t.value, t.data, t.operation));
    }

    function _sBless(uint256 e, address safe, bytes32 digest) private pure returns (bytes32) {
        return keccak256(abi.encode("CoWSafeWrapper.BLESS", e, safe, digest));
    }

    function _tload(bytes32 slot) private view returns (uint256 v) { assembly { v := tload(slot) } }
    function _tstore(bytes32 slot, uint256 v) private { assembly { tstore(slot, v) } }

    // uid = digest(32) ++ owner(20) ++ validTo(4)
    function _digest(bytes memory uid) private pure returns (bytes32 d) { assembly { d := mload(add(uid, 32)) } }
    function _uidOwner(bytes memory uid) private pure returns (address o) {
        assembly { o := shr(96, mload(add(uid, 64))) } // bytes [32:52]
    }
}
