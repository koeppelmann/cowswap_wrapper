// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISafeModules { function enableModule(address module) external; }
interface IERC20Approve { function approve(address, uint256) external returns (bool); }

/**
 * @title SafeModuleSetup
 * @notice Test/integration helper. Run via DELEGATECALL from `Safe.setup` (the `to`/`data` args) at
 *         Safe creation time, in the new Safe's own context: enable a module and approve a spender for a
 *         token. One-shot, no state. In production an app wires a wrapper the same way (module +
 *         fallback handler at creation, or via later owner txs).
 */
contract SafeModuleSetup {
    function setup(address module, address token, address spender) external {
        ISafeModules(address(this)).enableModule(module);
        IERC20Approve(token).approve(spender, type(uint256).max);
    }
}
