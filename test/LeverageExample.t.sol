// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSafeWrapper} from "../src/CoWSafeWrapper.sol";
import {CoWSafeSigHandler} from "../src/CoWSafeSigHandler.sol";
import {CowFlashLoanWrapper, IAavePoolFL} from "../src/CowFlashLoanWrapper.sol";
import {SafeModuleSetup} from "./helpers/SafeModuleSetup.sol";
import {ICowSettlement, ICowWrapper} from "../src/CowWrapper.sol";

/*
 * MODEL A e2e: GENERIC double-wrapper leverage on a Gnosis shadow-fork.
 *   chain: solver → CowFlashLoanWrapper (real Aave V3 flash loan)
 *                      → CoWSafeWrapper (hash-committed Safe pre/post)
 *                          → REAL GPv2Settlement.settle (buffer liquidity)
 *
 * Covers the full leverage lifecycle: OPEN (flash WXDAI → sell for WETH → supply+borrow → repay flash)
 * and CLOSE (flash WXDAI → repay debt + withdraw → sell WETH → repay flash, equity stays in Safe).
 * MultiSendCallOnly (delegatecall, hash-committed) batches the multi-step pre/post.
 *
 * Run: GNOSIS_RPC=https://rpc.gnosischain.com forge test --match-path test/LeverageExample.t.sol -vv
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}
interface ISafeFactory { function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce) external returns (address); }
interface ISafeSetup {
    function setup(address[] calldata owners, uint256 threshold, address to, bytes calldata data, address fallbackHandler, address paymentToken, uint256 payment, address paymentReceiver) external;
}
interface ISettlement {
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
    function authenticator() external view returns (address);
    function filledAmount(bytes calldata) external view returns (uint256);
}
interface IAuth { function addSolver(address) external; function manager() external view returns (address); }
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getUserAccountData(address user) external view returns (uint256,uint256,uint256,uint256,uint256,uint256);
    function ADDRESSES_PROVIDER() external view returns (address);
}
interface IAddressesProvider { function getPriceOracle() external view returns (address); }
interface IAaveOracle { function getAssetPrice(address asset) external view returns (uint256); } // USD 1e8

contract LeverageExampleTest is Test {
    address constant FACTORY    = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SINGLETON  = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;
    address constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address constant MULTISEND  = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D; // MultiSendCallOnly v1.3.0
    address constant WXDAI      = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address constant WETH       = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address constant POOL       = 0xb50201558B00496A145fE76f7424749556E326D8;

    bytes32 constant ORDER_TYPE_HASH = 0xd5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489;
    bytes32 constant KIND_SELL       = 0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775;
    bytes32 constant BALANCE_ERC20   = 0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9;
    bytes4  constant SETTLE_SELECTOR = 0x13d79a0b;

    CoWSafeWrapper safeWrapper;
    CowFlashLoanWrapper flashWrapper;
    CoWSafeSigHandler handler;
    address solver;
    address safe;
    address owner;
    uint256 ownerPk = 0xA11CE;
    address vaultRelayer;

    // ---- OPEN economics: equity 100 WXDAI, 2x → flash 200, premium 0.1, borrow 100.1 ----
    uint256 constant EQUITY   = 100e18;
    uint256 constant FLASH    = 200e18;
    uint256 constant PREMIUM  = 1e17;            // 200 * 0.05%
    uint256 constant REPAY    = FLASH + PREMIUM; // 200.1
    uint256 constant BORROW   = REPAY - EQUITY;  // 100.1
    uint256 BUY_WETH;                            // 200 WXDAI worth of WETH at the AAVE ORACLE price

    // ---- CLOSE economics: flash 101 (covers 100.1 debt), premium 0.0505 ----
    uint256 constant CFLASH   = 101e18;
    uint256 constant CPREMIUM = 505e14;            // 101 * 0.05% = 0.0505
    uint256 constant CREPAY   = CFLASH + CPREMIUM; // 101.0505
    uint256 SELL_WETH;                             // sell all collateral
    uint256 CBUY_WXDAI;                            // proceeds at oracle price, 1% slippage

    struct Trade {
        uint256 sellTokenIndex; uint256 buyTokenIndex; address receiver; uint256 sellAmount; uint256 buyAmount;
        uint32 validTo; bytes32 appData; uint256 feeAmount; uint256 flags; uint256 executedAmount; bytes signature;
    }
    struct Interaction { address target; uint256 value; bytes callData; }

    uint32 validTo;

    function setUp() public {
        vm.createSelectFork(vm.envString("GNOSIS_RPC"));
        owner = vm.addr(ownerPk);
        solver = address(0x5012E2);
        validTo = uint32(block.timestamp + 3600);
        vaultRelayer = ISettlement(SETTLEMENT).vaultRelayer();

        safeWrapper = new CoWSafeWrapper(ICowSettlement(SETTLEMENT));
        flashWrapper = new CowFlashLoanWrapper(ICowSettlement(SETTLEMENT), IAavePoolFL(POOL));
        handler = new CoWSafeSigHandler(address(safeWrapper), SETTLEMENT);

        // chain rule: every wrapper checks isSolver(caller); settlement checks isSolver(last wrapper)
        IAuth auth = IAuth(ISettlement(SETTLEMENT).authenticator());
        vm.startPrank(IAuth(address(auth)).manager());
        auth.addSolver(solver);                  // drives flashWrapper
        auth.addSolver(address(flashWrapper));   // drives safeWrapper
        auth.addSolver(address(safeWrapper));    // drives settlement
        vm.stopPrank();

        // Safe: owner EOA, module = safeWrapper, fallback = handler, approve relayer for WXDAI (sell side of OPEN)
        SafeModuleSetup init = new SafeModuleSetup();
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory initData = abi.encodeWithSelector(SafeModuleSetup.setup.selector, address(safeWrapper), WXDAI, vaultRelayer);
        bytes memory initializer = abi.encodeWithSelector(
            ISafeSetup.setup.selector, owners, uint256(1), address(init), initData, address(handler), address(0), uint256(0), address(0)
        );
        safe = ISafeFactory(FACTORY).createProxyWithNonce(SINGLETON, initializer, 0xC0FFEE);

        deal(WXDAI, safe, EQUITY); // user funds the position Safe with equity

        // swap rates from the AAVE ORACLE (like a real solver quoting at market): WXDAI≈$1, WETH=oracle
        address oracle = IAddressesProvider(IAavePool(POOL).ADDRESSES_PROVIDER()).getPriceOracle();
        uint256 pWeth = IAaveOracle(oracle).getAssetPrice(WETH);    // USD 1e8
        uint256 pDai  = IAaveOracle(oracle).getAssetPrice(WXDAI);   // USD 1e8
        BUY_WETH   = (FLASH * pDai) / pWeth;                        // 200 WXDAI worth of WETH
        SELL_WETH  = BUY_WETH - 1e9;                                // dust margin: aToken withdraw can round 1 wei down
        CBUY_WXDAI = (SELL_WETH * pWeth) / pDai * 99 / 100;         // proceeds, 1% slippage
    }

    // ================= helpers =================
    function _digest(address s, address sellT, address buyT, uint256 sellA, uint256 buyA) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPE_HASH, sellT, buyT, s, sellA, buyA, validTo, bytes32(0), uint256(0),
            KIND_SELL, false, BALANCE_ERC20, BALANCE_ERC20
        ));
        return keccak256(abi.encodePacked("\x19\x01", ISettlement(SETTLEMENT).domainSeparator(), structHash));
    }
    function _uid(address s, address sellT, address buyT, uint256 sellA, uint256 buyA) internal view returns (bytes memory) {
        return abi.encodePacked(_digest(s, sellT, buyT, sellA, buyA), s, validTo);
    }

    /// MultiSendCallOnly payload: packed [op(1)=0][to(20)][value(32)][dataLen(32)][data] per call
    function _ms(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }
    function _multiSendTx(bytes memory packedCalls) internal pure returns (CoWSafeWrapper.SafeTx memory) {
        return CoWSafeWrapper.SafeTx({
            to: MULTISEND, value: 0,
            data: abi.encodeWithSignature("multiSend(bytes)", packedCalls),
            operation: 1 // DELEGATECALL into MultiSendCallOnly (inner txs are CALL-only)
        });
    }
    function _h(CoWSafeWrapper.SafeTx memory t) internal pure returns (bytes32) {
        return keccak256(abi.encode(t.to, t.value, t.data, t.operation));
    }

    /// settle with buffer liquidity (Kaze method): output token pre-dealt to settlement, no interactions
    function _settleCd(address sellT, address buyT, uint256 sellA, uint256 buyA) internal view returns (bytes memory) {
        address[] memory tokens = new address[](2); tokens[0] = sellT; tokens[1] = buyT;
        uint256[] memory prices = new uint256[](2); prices[0] = buyA; prices[1] = sellA;
        Trade[] memory trades = new Trade[](1);
        trades[0] = Trade({
            sellTokenIndex: 0, buyTokenIndex: 1, receiver: safe, sellAmount: sellA, buyAmount: buyA,
            validTo: validTo, appData: bytes32(0), feeAmount: 0, flags: 0x40, executedAmount: sellA, signature: abi.encodePacked(safe)
        });
        Interaction[] memory empty = new Interaction[](0);
        Interaction[][3] memory interactions = [empty, empty, empty];
        return abi.encodeWithSelector(SETTLE_SELECTOR, tokens, prices, trades, interactions);
    }

    /// chainedWrapperData for flashWrapper(first) → safeWrapper(final):
    /// [len_fl][abi.encode(Loan[])] [addr safeWrapper] [len_safe][abi.encode(OrderExec[])]
    function _chain(CowFlashLoanWrapper.Loan[] memory loans, CoWSafeWrapper.OrderExec[] memory ex)
        internal view returns (bytes memory)
    {
        bytes memory flData = abi.encode(loans); // Loan[] only — fill enforcement lives in CoWSafeWrapper
        bytes memory safeData = abi.encode(ex);
        return bytes.concat(
            bytes2(uint16(flData.length)), flData,
            bytes20(address(safeWrapper)),
            bytes2(uint16(safeData.length)), safeData
        );
    }

    function _loan1(address token, uint256 amount, address recipient) internal pure returns (CowFlashLoanWrapper.Loan[] memory l) {
        l = new CowFlashLoanWrapper.Loan[](1);
        l[0] = CowFlashLoanWrapper.Loan({ token: token, amount: amount, recipient: recipient });
    }
    function _exec1(uint256 nonce, CoWSafeWrapper.SafeTx memory pre, CoWSafeWrapper.SafeTx memory post)
        internal view returns (CoWSafeWrapper.OrderExec[] memory e)
    {
        e = new CoWSafeWrapper.OrderExec[](1);
        e[0] = CoWSafeWrapper.OrderExec({ safe: safe, nonce: nonce, pre: pre, post: post });
    }

    // ================= OPEN =================
    function _openTxs() internal view returns (CoWSafeWrapper.SafeTx memory pre, CoWSafeWrapper.SafeTx memory post) {
        // pre (CALL): approve Aave pool to pull WETH for supply
        pre = CoWSafeWrapper.SafeTx({ to: WETH, value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, POOL, type(uint256).max), operation: 0 });
        // post (DELEGATECALL MultiSendCallOnly): supply WETH, borrow WXDAI, repay flash wrapper
        bytes memory calls = bytes.concat(
            _ms(POOL,  abi.encodeWithSelector(IAavePool.supply.selector, WETH, BUY_WETH, safe, uint16(0))),
            _ms(POOL,  abi.encodeWithSelector(IAavePool.borrow.selector, WXDAI, BORROW, uint256(2), uint16(0), safe)),
            _ms(WXDAI, abi.encodeWithSelector(IERC20.transfer.selector, address(flashWrapper), REPAY))
        );
        post = _multiSendTx(calls);
    }

    function _registerOpen(uint256 nonce) internal {
        (CoWSafeWrapper.SafeTx memory pre, CoWSafeWrapper.SafeTx memory post) = _openTxs();
        CoWSafeWrapper.MetaOrder memory m = CoWSafeWrapper.MetaOrder({
            uid: _uid(safe, WXDAI, WETH, FLASH, BUY_WETH), expectedFill: FLASH,
            preHash: _h(pre), postHash: _h(post), notBefore: 0, deadline: 0, status: 0
        });
        vm.prank(safe);
        safeWrapper.registerMetaOrder(nonce, m);
    }

    function _open() internal {
        _registerOpen(1);
        deal(WETH, SETTLEMENT, BUY_WETH); // buffer liquidity for the buy side
        (CoWSafeWrapper.SafeTx memory pre, CoWSafeWrapper.SafeTx memory post) = _openTxs();
        bytes memory chain = _chain(_loan1(WXDAI, FLASH, safe), _exec1(1, pre, post));
        vm.prank(solver);
        uint256 g = gasleft();
        flashWrapper.wrappedSettle(_settleCd(WXDAI, WETH, FLASH, BUY_WETH), chain);
        emit log_named_uint("GAS open (model A settle tx)", g - gasleft());
    }

    function test_open_2x_long_via_double_wrapper() public {
        _open();
        // order filled
        assertEq(ISettlement(SETTLEMENT).filledAmount(_uid(safe, WXDAI, WETH, FLASH, BUY_WETH)), FLASH, "order filled");
        // position: collateral > 0, debt == BORROW (same-block, no accrual)
        (uint256 coll, uint256 debt,,,,) = IAavePool(POOL).getUserAccountData(safe);
        assertGt(coll, 0, "collateral supplied");
        assertGt(debt, 0, "debt opened");
        // no dust: safe spent ALL WXDAI (equity + borrow went to flash repay), holds no WETH (supplied)
        assertEq(IERC20(WXDAI).balanceOf(safe), 0, "no WXDAI dust");
        assertEq(IERC20(WETH).balanceOf(safe), 0, "all WETH supplied");
        // flash wrapper is empty (loan + premium pulled by Aave)
        assertEq(IERC20(WXDAI).balanceOf(address(flashWrapper)), 0, "flash repaid exactly");
        // meta-order consumed
        assertEq(safeWrapper.orderStatus(safe, 1), 2, "consumed");
        emit log_named_decimal_uint("collateral (USD 1e8)", coll, 8);
        emit log_named_decimal_uint("debt       (USD 1e8)", debt, 8);
    }

    // ================= CLOSE =================
    function _closeTxs() internal view returns (CoWSafeWrapper.SafeTx memory pre, CoWSafeWrapper.SafeTx memory post) {
        // pre (DELEGATECALL MultiSend): approve+repay debt, withdraw collateral, approve relayer for WETH
        bytes memory preCalls = bytes.concat(
            _ms(WXDAI, abi.encodeWithSelector(IERC20.approve.selector, POOL, CFLASH)),
            _ms(POOL,  abi.encodeWithSelector(IAavePool.repay.selector, WXDAI, type(uint256).max, uint256(2), safe)),
            _ms(POOL,  abi.encodeWithSelector(IAavePool.withdraw.selector, WETH, type(uint256).max, safe)),
            _ms(WETH,  abi.encodeWithSelector(IERC20.approve.selector, vaultRelayer, SELL_WETH))
        );
        pre = _multiSendTx(preCalls);
        // post (CALL): repay the flash wrapper; remaining equity stays in the Safe
        post = CoWSafeWrapper.SafeTx({ to: WXDAI, value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, address(flashWrapper), CREPAY), operation: 0 });
    }

    function test_close_via_double_wrapper() public {
        _open();
        // -- now close --
        (CoWSafeWrapper.SafeTx memory pre, CoWSafeWrapper.SafeTx memory post) = _closeTxs();
        CoWSafeWrapper.MetaOrder memory m = CoWSafeWrapper.MetaOrder({
            uid: _uid(safe, WETH, WXDAI, SELL_WETH, CBUY_WXDAI), expectedFill: SELL_WETH,
            preHash: _h(pre), postHash: _h(post), notBefore: 0, deadline: 0, status: 0
        });
        vm.prank(safe);
        safeWrapper.registerMetaOrder(2, m);

        deal(WXDAI, SETTLEMENT, CBUY_WXDAI); // buffer liquidity for the buy side
        bytes memory chain = _chain(_loan1(WXDAI, CFLASH, safe), _exec1(2, pre, post));
        vm.prank(solver);
        uint256 g = gasleft();
        flashWrapper.wrappedSettle(_settleCd(WETH, WXDAI, SELL_WETH, CBUY_WXDAI), chain);
        emit log_named_uint("GAS close (model A settle tx)", g - gasleft());

        // position fully closed
        (uint256 coll, uint256 debt,,,,) = IAavePool(POOL).getUserAccountData(safe);
        assertEq(debt, 0, "debt repaid");
        assertEq(coll, 0, "collateral withdrawn");
        // equity recovered in the Safe (~ EQUITY + price gain - premiums); owner can withdraw any time
        uint256 recovered = IERC20(WXDAI).balanceOf(safe);
        // ~100 equity back, minus flash premiums + the 1% modeled close slippage (≈97.85); a real leak
        // would fall outside this band
        assertGt(recovered, 97e18, "equity recovered (lower band)");
        assertLt(recovered, 99e18, "equity recovered (upper band)");
        assertLt(IERC20(WETH).balanceOf(safe), 1e15, "no meaningful WETH dust left in the Safe");
        assertEq(IERC20(WXDAI).balanceOf(address(flashWrapper)), 0, "flash repaid exactly");
        assertEq(safeWrapper.orderStatus(safe, 2), 2, "consumed");
        emit log_named_decimal_uint("equity recovered (WXDAI)", recovered, 18);
    }

    // ================= negatives =================
    function test_reject_thirdParty_flashloan_callback() public {
        // direct pool.flashLoan with receiver = flashWrapper from an attacker → initiator != wrapper → revert
        address[] memory assets = new address[](1); assets[0] = WXDAI;
        uint256[] memory amounts = new uint256[](1); amounts[0] = 1e18;
        uint256[] memory modes = new uint256[](1);
        address[] memory recipients = new address[](1); recipients[0] = address(0xBAD);
        recipients; // unused once params decode is unreachable (reverts at the initiator gate first)
        vm.prank(address(0xBAD));
        vm.expectRevert(CowFlashLoanWrapper.NotSelfInitiated.selector); // initiator != wrapper
        IAavePoolFL(POOL).flashLoan(address(flashWrapper), assets, amounts, modes, address(0xBAD), bytes(""), 0);
    }

    function test_reject_direct_executeOperation() public {
        address[] memory assets = new address[](1); assets[0] = WXDAI;
        uint256[] memory amounts = new uint256[](1); amounts[0] = 1e18;
        uint256[] memory premiums = new uint256[](1);
        vm.expectRevert(CowFlashLoanWrapper.NotPool.selector); // caller is not the Aave pool
        flashWrapper.executeOperation(assets, amounts, premiums, address(flashWrapper), bytes(""));
    }

    function test_reject_tampered_post_in_chain() public {
        _registerOpen(1);
        deal(WETH, SETTLEMENT, BUY_WETH);
        (CoWSafeWrapper.SafeTx memory pre, ) = _openTxs();
        // tampered post: send the repay to the ATTACKER instead of the flash wrapper
        CoWSafeWrapper.SafeTx memory evil = CoWSafeWrapper.SafeTx({ to: WXDAI, value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, address(0xBAD), REPAY), operation: 0 });
        bytes memory chain = _chain(_loan1(WXDAI, FLASH, safe), _exec1(1, pre, evil));
        vm.prank(solver);
        vm.expectRevert(bytes("post mismatch")); // hash check inside CoWSafeWrapper → whole chain reverts
        flashWrapper.wrappedSettle(_settleCd(WXDAI, WETH, FLASH, BUY_WETH), chain);
    }

    function test_reject_unrepaid_flashloan() public {
        // loan routed to a recipient that never repays → Aave pull fails → whole tx reverts
        _registerOpen(1);
        deal(WETH, SETTLEMENT, BUY_WETH);
        (CoWSafeWrapper.SafeTx memory pre, CoWSafeWrapper.SafeTx memory post) = _openTxs();
        // loan goes to 0xBAD instead of the safe: safe can't sell (no WXDAI beyond equity) → settle reverts
        bytes memory chain = _chain(_loan1(WXDAI, FLASH, address(0xBAD)), _exec1(1, pre, post));
        vm.prank(solver);
        vm.expectRevert();
        flashWrapper.wrappedSettle(_settleCd(WXDAI, WETH, FLASH, BUY_WETH), chain);
    }

    /// Design note: the flash layer is a GENERIC liquidity primitive and deliberately does NOT verify
    /// that the downstream filled any order — fill-correctness is enforced by CoWSafeWrapper
    /// (filledAmount >= expectedFill). A downstream that repays the loan and returns the magic value
    /// therefore succeeds AT THE FLASH LAYER; it simply can't fake a fill on a user's Safe order.
    function test_flashLayer_doesNotEnforceFill() public {
        FakeWrapper fake = new FakeWrapper(WXDAI, address(flashWrapper));
        deal(WXDAI, address(fake), REPAY); // fake repays loan+premium from its own funds
        bytes memory flData = abi.encode(_loan1(WXDAI, FLASH, address(fake)));
        bytes memory chain = bytes.concat(bytes2(uint16(flData.length)), flData, bytes20(address(fake)), bytes2(uint16(0)));
        vm.prank(solver);
        bytes4 ret = flashWrapper.wrappedSettle(_settleCd(WXDAI, WETH, FLASH, BUY_WETH), chain);
        assertEq(ret, ICowWrapper.wrappedSettle.selector, "flash layer succeeds; fill is CoWSafeWrapper's job");
    }
}

/// A "wrapper" that returns the magic value and repays the loan from its own balance without settling.
contract FakeWrapper {
    address immutable token; address immutable flashWrapper;
    constructor(address t, address fw) { token = t; flashWrapper = fw; }
    function wrappedSettle(bytes calldata, bytes calldata) external returns (bytes4) {
        IERC20(token).transfer(flashWrapper, IERC20(token).balanceOf(address(this)));
        return this.wrappedSettle.selector; // same selector as ICowWrapper.wrappedSettle → passes the magic check
    }
}
