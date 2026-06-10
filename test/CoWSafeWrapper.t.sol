// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CoWSafeWrapper} from "../src/CoWSafeWrapper.sol";
import {CoWSafeSigHandler} from "../src/CoWSafeSigHandler.sol";
import {SafeModuleSetup} from "./helpers/SafeModuleSetup.sol";
import {CowWrapper, ICowSettlement} from "../src/CowWrapper.sol";

/*
 * End-to-end shadow-fork test of the ICowWrapper-compliant CoWSafeWrapper, with pre/post stored as
 * HASHES on-chain and the actual calldata supplied at settle time (wrapperData = abi.encode(OrderExec[])).
 * Run: GNOSIS_RPC=https://rpc.gnosischain.com forge test --match-path test/CoWSafeWrapper.t.sol -vv
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}
interface ISafeFactory { function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce) external returns (address); }
interface ISafeSetup {
    function setup(address[] calldata owners, uint256 threshold, address to, bytes calldata data, address fallbackHandler, address paymentToken, uint256 payment, address paymentReceiver) external;
    function isModuleEnabled(address) external view returns (bool);
}
interface ISettlement {
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
    function authenticator() external view returns (address);
    function filledAmount(bytes calldata) external view returns (uint256);
}
interface IAuth { function addSolver(address) external; function manager() external view returns (address); function isSolver(address) external view returns (bool); }
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function getUserAccountData(address user) external view returns (uint256,uint256,uint256,uint256,uint256,uint256);
}
interface IERC20Approve { function approve(address, uint256) external returns (bool); }

contract MockTrader { function provide(address token, address to, uint256 amount) external { IERC20(token).transfer(to, amount); } }
contract Probe { address public lastCaller; uint256 public count; function ping() external { lastCaller = msg.sender; count++; } }

contract CoWSafeWrapperTest is Test {
    address constant FACTORY    = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SINGLETON  = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E; // SafeL2 v1.3.0
    address constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address constant WXDAI      = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address constant WETH       = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address constant AAVE_POOL  = 0xb50201558B00496A145fE76f7424749556E326D8;

    bytes32 constant ORDER_TYPE_HASH = 0xd5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489;
    bytes32 constant KIND_SELL       = 0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775;
    bytes32 constant BALANCE_ERC20   = 0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9;
    bytes4  constant SETTLE_SELECTOR = 0x13d79a0b;

    CoWSafeWrapper wrapper;
    CoWSafeSigHandler handler;
    MockTrader trader;
    Probe probe;
    address solver;
    address safe;
    address owner;
    uint256 ownerPk = 0xA11CE;
    address vaultRelayer;

    uint256 constant SELL = 100e18;
    uint256 constant BUY  = 1e16;
    uint32  validTo;

    struct Trade {
        uint256 sellTokenIndex; uint256 buyTokenIndex; address receiver; uint256 sellAmount; uint256 buyAmount;
        uint32 validTo; bytes32 appData; uint256 feeAmount; uint256 flags; uint256 executedAmount; bytes signature;
    }
    struct Interaction { address target; uint256 value; bytes callData; }

    function setUp() public {
        vm.createSelectFork(vm.envString("GNOSIS_RPC"));
        owner = vm.addr(ownerPk);
        solver = address(0x5012E2);
        validTo = uint32(block.timestamp + 3600);
        vaultRelayer = ISettlement(SETTLEMENT).vaultRelayer();

        wrapper = new CoWSafeWrapper(ICowSettlement(SETTLEMENT));
        handler = new CoWSafeSigHandler(address(wrapper), SETTLEMENT);
        trader = new MockTrader();
        probe = new Probe();

        IAuth auth = IAuth(ISettlement(SETTLEMENT).authenticator());
        vm.startPrank(auth.manager());
        auth.addSolver(address(wrapper));
        auth.addSolver(solver);
        vm.stopPrank();

        safe = _createSafe(uint256(uint160(address(this))));
    }

    // ---------- order/uid helpers ----------
    function _digestFor(address s) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPE_HASH, WXDAI, WETH, s, SELL, BUY, validTo, bytes32(0), uint256(0),
            KIND_SELL, false, BALANCE_ERC20, BALANCE_ERC20
        ));
        return keccak256(abi.encodePacked("\x19\x01", ISettlement(SETTLEMENT).domainSeparator(), structHash));
    }
    function _uidFor(address s) internal view returns (bytes memory) { return abi.encodePacked(_digestFor(s), s, validTo); }
    function _orderDigest() internal view returns (bytes32) { return _digestFor(safe); }
    function _uid() internal view returns (bytes memory) { return _uidFor(safe); }

    function _createSafe(uint256 salt) internal returns (address s) {
        SafeModuleSetup init = new SafeModuleSetup();
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory initData = abi.encodeWithSelector(SafeModuleSetup.setup.selector, address(wrapper), WXDAI, vaultRelayer);
        bytes memory initializer = abi.encodeWithSelector(
            ISafeSetup.setup.selector, owners, uint256(1), address(init), initData, address(handler), address(0), uint256(0), address(0)
        );
        s = ISafeFactory(FACTORY).createProxyWithNonce(SINGLETON, initializer, salt);
    }

    // ---------- pre/post + meta-order helpers (hash model) ----------
    function _preTx(address) internal view returns (CoWSafeWrapper.SafeTx memory) {
        return CoWSafeWrapper.SafeTx({ to: address(probe), value: 0, data: abi.encodeWithSelector(Probe.ping.selector), operation: 0 });
    }
    function _postTx(address) internal view returns (CoWSafeWrapper.SafeTx memory) {
        return CoWSafeWrapper.SafeTx({ to: WETH, value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, owner, BUY), operation: 0 });
    }
    function _h(CoWSafeWrapper.SafeTx memory t) internal pure returns (bytes32) {
        return keccak256(abi.encode(t.to, t.value, t.data, t.operation)); // mirrors wrapper._hashSafeTx
    }
    function _meta(address s, bytes32 preH, bytes32 postH) internal view returns (CoWSafeWrapper.MetaOrder memory m) {
        m = CoWSafeWrapper.MetaOrder({ uid: _uidFor(s), expectedFill: SELL, preHash: preH, postHash: postH, notBefore: 0, deadline: 0, status: 0 });
    }
    function _registerFor(address s, uint256 nonce) internal {
        CoWSafeWrapper.MetaOrder memory m = _meta(s, _h(_preTx(s)), _h(_postTx(s))); // external (domainSeparator) before prank
        vm.prank(s);
        wrapper.registerMetaOrder(nonce, m);
    }
    function _register(uint256 nonce) internal { _registerFor(safe, nonce); }

    function _exec1(address s, uint256 nonce) internal view returns (CoWSafeWrapper.OrderExec[] memory e) {
        e = new CoWSafeWrapper.OrderExec[](1);
        e[0] = CoWSafeWrapper.OrderExec({ safe: s, nonce: nonce, pre: _preTx(s), post: _postTx(s) });
    }
    /// encode a single-wrapper (final) chain: [uint16 len][abi.encode(OrderExec[])]
    function _chained(CoWSafeWrapper.OrderExec[] memory e) internal pure returns (bytes memory) {
        bytes memory wd = abi.encode(e);
        return bytes.concat(bytes2(uint16(wd.length)), wd);
    }

    function _trade(address s) internal view returns (Trade memory) {
        return Trade({
            sellTokenIndex: 0, buyTokenIndex: 1, receiver: s, sellAmount: SELL, buyAmount: BUY,
            validTo: validTo, appData: bytes32(0), feeAmount: 0, flags: 0x40, executedAmount: SELL, signature: abi.encodePacked(s)
        });
    }
    function _settleCalldata(bool includeTrade) internal view returns (bytes memory) {
        address[] memory tokens = new address[](2); tokens[0] = WXDAI; tokens[1] = WETH;
        uint256[] memory prices = new uint256[](2); prices[0] = BUY; prices[1] = SELL;
        Trade[] memory trades = new Trade[](includeTrade ? 1 : 0);
        if (includeTrade) trades[0] = _trade(safe);
        Interaction[] memory pre = new Interaction[](0);
        Interaction[] memory intra = new Interaction[](includeTrade ? 2 : 0);
        if (includeTrade) {
            intra[0] = Interaction({ target: WXDAI, value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, address(trader), SELL) });
            intra[1] = Interaction({ target: address(trader), value: 0, callData: abi.encodeWithSelector(MockTrader.provide.selector, WETH, SETTLEMENT, BUY) });
        }
        Interaction[] memory post = new Interaction[](0);
        Interaction[][3] memory interactions = [pre, intra, post];
        return abi.encodeWithSelector(SETTLE_SELECTOR, tokens, prices, trades, interactions);
    }
    function _settleNoInteractions() internal view returns (bytes memory) {
        address[] memory tokens = new address[](2); tokens[0] = WXDAI; tokens[1] = WETH;
        uint256[] memory prices = new uint256[](2); prices[0] = BUY; prices[1] = SELL;
        Trade[] memory trades = new Trade[](1); trades[0] = _trade(safe);
        Interaction[] memory empty = new Interaction[](0);
        Interaction[][3] memory interactions = [empty, empty, empty];
        return abi.encodeWithSelector(SETTLE_SELECTOR, tokens, prices, trades, interactions);
    }
    function _fund() internal { deal(WXDAI, safe, SELL); deal(WETH, address(trader), BUY); }

    // ---------- tests ----------
    function test_wiring() public view {
        assertTrue(ISafeSetup(safe).isModuleEnabled(address(wrapper)), "module enabled");
        assertEq(IERC20(WXDAI).allowance(safe, vaultRelayer), type(uint256).max, "relayer approved");
        assertTrue(IAuth(ISettlement(SETTLEMENT).authenticator()).isSolver(address(wrapper)), "wrapper is solver");
        assertEq(address(wrapper.AUTHENTICATOR()), ISettlement(SETTLEMENT).authenticator(), "authenticator wired");
    }

    function test_happy_path() public {
        _fund(); _register(1);
        uint256 before = IERC20(WETH).balanceOf(owner);
        vm.prank(solver);
        wrapper.wrappedSettle(_settleCalldata(true), _chained(_exec1(safe, 1)));
        assertEq(probe.count(), 1, "pre ran");
        assertEq(probe.lastCaller(), safe, "pre ran AS the safe");
        assertEq(ISettlement(SETTLEMENT).filledAmount(_uid()), SELL, "filled");
        assertEq(IERC20(WETH).balanceOf(owner) - before, BUY, "post paid owner");
        assertEq(wrapper.orderStatus(safe, 1), 2, "consumed");
    }

    function test_happy_path_kaze_buffer() public {
        deal(WXDAI, safe, SELL);
        deal(WETH, SETTLEMENT, BUY);
        _register(1);
        uint256 before = IERC20(WETH).balanceOf(owner);
        vm.prank(solver);
        wrapper.wrappedSettle(_settleNoInteractions(), _chained(_exec1(safe, 1)));
        assertEq(probe.count(), 1, "pre ran");
        assertEq(ISettlement(SETTLEMENT).filledAmount(_uid()), SELL, "filled (buffer)");
        assertEq(IERC20(WETH).balanceOf(owner) - before, BUY, "post paid owner");
        assertEq(wrapper.orderStatus(safe, 1), 2, "consumed");
    }

    function test_real_aave_supply_via_wrapper() public {
        _fund();
        CoWSafeWrapper.SafeTx memory pre = CoWSafeWrapper.SafeTx({ to: WETH, value: 0, data: abi.encodeWithSelector(IERC20Approve.approve.selector, AAVE_POOL, type(uint256).max), operation: 0 });
        CoWSafeWrapper.SafeTx memory post = CoWSafeWrapper.SafeTx({ to: AAVE_POOL, value: 0, data: abi.encodeWithSelector(IAavePool.supply.selector, WETH, BUY, safe, uint16(0)), operation: 0 });
        CoWSafeWrapper.MetaOrder memory m = _meta(safe, _h(pre), _h(post));
        vm.prank(safe); wrapper.registerMetaOrder(1, m);

        CoWSafeWrapper.OrderExec[] memory e = new CoWSafeWrapper.OrderExec[](1);
        e[0] = CoWSafeWrapper.OrderExec({ safe: safe, nonce: 1, pre: pre, post: post });

        (uint256 collBefore,,,,,) = IAavePool(AAVE_POOL).getUserAccountData(safe);
        vm.prank(solver);
        wrapper.wrappedSettle(_settleCalldata(true), _chained(e));
        assertEq(ISettlement(SETTLEMENT).filledAmount(_uid()), SELL, "filled");
        (uint256 collAfter,,,,,) = IAavePool(AAVE_POOL).getUserAccountData(safe);
        assertGt(collAfter, collBefore, "bought WETH supplied to Aave as the Safe");
        assertEq(wrapper.orderStatus(safe, 1), 2, "consumed");
    }

    function test_multi_order_two_safes_one_batch() public {
        address safe2 = _createSafe(uint256(uint160(address(this))) ^ 0x1234);
        deal(WXDAI, safe, SELL); deal(WXDAI, safe2, SELL); deal(WETH, address(trader), BUY * 2);
        _register(1); _registerFor(safe2, 1);

        address[] memory tokens = new address[](2); tokens[0] = WXDAI; tokens[1] = WETH;
        uint256[] memory prices = new uint256[](2); prices[0] = BUY; prices[1] = SELL;
        Trade[] memory trades = new Trade[](2); trades[0] = _trade(safe); trades[1] = _trade(safe2);
        Interaction[] memory pre = new Interaction[](0);
        Interaction[] memory intra = new Interaction[](2);
        intra[0] = Interaction({ target: WXDAI, value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, address(trader), SELL * 2) });
        intra[1] = Interaction({ target: address(trader), value: 0, callData: abi.encodeWithSelector(MockTrader.provide.selector, WETH, SETTLEMENT, BUY * 2) });
        Interaction[] memory post = new Interaction[](0);
        Interaction[][3] memory interactions = [pre, intra, post];
        bytes memory cd = abi.encodeWithSelector(SETTLE_SELECTOR, tokens, prices, trades, interactions);

        CoWSafeWrapper.OrderExec[] memory e = new CoWSafeWrapper.OrderExec[](2);
        e[0] = CoWSafeWrapper.OrderExec({ safe: safe,  nonce: 1, pre: _preTx(safe),  post: _postTx(safe) });
        e[1] = CoWSafeWrapper.OrderExec({ safe: safe2, nonce: 1, pre: _preTx(safe2), post: _postTx(safe2) });

        uint256 before = IERC20(WETH).balanceOf(owner);
        vm.prank(solver);
        wrapper.wrappedSettle(cd, _chained(e));
        assertEq(probe.count(), 2, "both pres ran");
        assertEq(ISettlement(SETTLEMENT).filledAmount(_uidFor(safe)), SELL, "order 1 filled");
        assertEq(ISettlement(SETTLEMENT).filledAmount(_uidFor(safe2)), SELL, "order 2 filled");
        assertEq(IERC20(WETH).balanceOf(owner) - before, BUY * 2, "both posts paid owner");
        assertEq(wrapper.orderStatus(safe, 1), 2);
        assertEq(wrapper.orderStatus(safe2, 1), 2);
    }

    // ---- negatives ----
    function test_reject_nonSolver() public {
        _fund(); _register(1);
        vm.expectRevert(abi.encodeWithSignature("NotASolver(address)", address(this)));
        wrapper.wrappedSettle(_settleCalldata(true), _chained(_exec1(safe, 1)));
    }

    function test_reject_emptyOrders() public {
        _fund();
        CoWSafeWrapper.OrderExec[] memory none = new CoWSafeWrapper.OrderExec[](0);
        vm.prank(solver);
        vm.expectRevert(bytes("items"));
        wrapper.wrappedSettle(_settleCalldata(true), _chained(none));
    }

    function test_reject_unregistered() public {
        _fund();
        vm.prank(solver);
        vm.expectRevert(bytes("not registered"));
        wrapper.wrappedSettle(_settleCalldata(true), _chained(_exec1(safe, 7)));
    }

    function test_reject_tampered_pre() public {
        _fund(); _register(1);
        // supply a pre that does NOT match the registered preHash
        CoWSafeWrapper.OrderExec[] memory e = _exec1(safe, 1);
        e[0].pre = CoWSafeWrapper.SafeTx({ to: WETH, value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, address(this), SELL), operation: 0 });
        vm.prank(solver);
        vm.expectRevert(bytes("pre mismatch"));
        wrapper.wrappedSettle(_settleCalldata(true), _chained(e));
    }

    function test_reject_directSettle_bypassBlocked() public {
        _fund(); _register(1);
        deal(WETH, SETTLEMENT, BUY);
        vm.prank(solver);
        (bool ok,) = SETTLEMENT.call(_settleNoInteractions());
        assertFalse(ok, "direct settle of a wrapped order must fail (not blessed)");
        assertEq(ISettlement(SETTLEMENT).filledAmount(_uid()), 0, "order not filled");
    }

    function test_reject_solverOmitsTrade() public {
        _fund(); _register(1);
        vm.prank(solver);
        vm.expectRevert(bytes("not settled"));
        wrapper.wrappedSettle(_settleCalldata(false), _chained(_exec1(safe, 1)));
    }

    function test_reject_replay_consumed() public {
        _fund(); _register(1);
        vm.prank(solver);
        wrapper.wrappedSettle(_settleCalldata(true), _chained(_exec1(safe, 1)));
        _fund();
        vm.prank(solver);
        vm.expectRevert(bytes("not registered"));
        wrapper.wrappedSettle(_settleCalldata(true), _chained(_exec1(safe, 1)));
    }

    function test_reject_notFinalWrapper() public {
        // bless window must cover only the direct settle — a chain that continues past us must revert
        _fund(); _register(1);
        bytes memory wd = abi.encode(_exec1(safe, 1));
        bytes memory chainWithMore = bytes.concat(bytes2(uint16(wd.length)), wd, bytes20(address(0xDEADBEEF)));
        vm.prank(solver);
        vm.expectRevert(bytes("must be final wrapper"));
        wrapper.wrappedSettle(_settleCalldata(true), chainWithMore);
    }

    function test_eip1271_failsOutsideSettle() public view {
        bytes32 digest = _orderDigest();
        (bool ok, bytes memory ret) = safe.staticcall(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", digest, bytes("")));
        assertTrue(ok, "call ok");
        assertEq(abi.decode(ret, (bytes4)), bytes4(0xffffffff), "unblessed -> FAIL");
    }
}
