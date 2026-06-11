# Deployments

All contracts are deployed **deterministically** via the Arachnid CREATE2 factory
`0x4e59b44847b379578588920cA78FbF26c0B4956C` (present at the same address on every chain). The deployed
address is a pure function of `(creation bytecode, constructor args, salt)`, so the same source +
settings reproduce the same address on any network.

- Compiler: solc **0.8.34**, optimizer **200 runs**, `evm_version = cancun` (EIP-1153 transient storage).
- Salts (ascii): `CoWSafeWrapper.v3`, `CoWSafeSigHandler.v3`, `CowFlashLoanWrapper.v6`,
  `CoWSafeSigHandlerSim.v1`.
- Constructors: `CoWSafeWrapper(ICowSettlement settlement)`, `CoWSafeSigHandler(address wrapper, address
  settlement)`, `CowFlashLoanWrapper(ICowSettlement settlement, IAavePool pool)`,
  `CoWSafeSigHandlerSim(address wrapper, address settlement)`.

## Gnosis Chain (chain id 100) — CoW **staging** settlement

These point at CoW Protocol's **staging/barn** settlement so the stack can be exercised end-to-end before
production allowlisting. All three are **verified on Sourcify (exact match)**.

| Contract | Address |
|---|---|
| **CoWSafeWrapper** | [`0x531636e6e18F3A52c283aCCda39D7185E4597A37`](https://gnosisscan.io/address/0x531636e6e18F3A52c283aCCda39D7185E4597A37) |
| **CoWSafeSigHandler** | [`0x29619484de063A3E06e432a0CCBF5a2BE6F024DC`](https://gnosisscan.io/address/0x29619484de063A3E06e432a0CCBF5a2BE6F024DC) |
| **CowFlashLoanWrapper** | [`0x2E3fdEe28D7224ED140B4ea08C57F47546679363`](https://gnosisscan.io/address/0x2E3fdEe28D7224ED140B4ea08C57F47546679363) |
| **CoWSafeSigHandlerSim** | [`0xCc9AC16653530C141D946973fcae3d9E3815dE46`](https://gnosisscan.io/address/0xCc9AC16653530C141D946973fcae3d9E3815dE46) |

`CoWSafeSigHandlerSim` is the **simulation-validity** variant of the fallback handler: identical to
`CoWSafeSigHandler` except that on the CoW settlement path it returns the EIP-1271 magic value when
`tx.gasprice == 0` (true only in `eth_call`-style simulations, never in a real transaction). This lets
wrapper orders be submitted to the orderbook with `signingScheme: eip1271` directly — no
`setPreSignature` step — while on-chain validity remains bless-only. Proven live on Gnosis staging
2026-06-11: an eip1271 order was accepted by the barn orderbook and organically settled through the
wrapper (settlement tx
[`0xcfa258c9…83fc`](https://gnosisscan.io/tx/0xcfa258c90782ae157aa27b0550e7e594e8011d0f57e7a34075246ca386d383fc)).

External addresses used:
- CoW staging settlement: `0xf553d092b50bdcbddeD1A99aF2cA29FBE5E2CB13` (authenticator `0x02073540567FA1EABcBf74C2F7E6F9029ca7d800`, vaultRelayer `0xC7242d167563352E2BCA4d71C043fbe542DB8FB2`)
- Aave V3 Pool: `0xb50201558B00496A145fE76f7424749556E326D8`
- CoW **production** settlement (same on all CoW chains): `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`

### `CowFlashLoanWrapper` changelog (addresses the review issues #1–#4)

`v6` (`0x2E3fdEe28D7224ED140B4ea08C57F47546679363`, salt `CowFlashLoanWrapper.v6`) is the current build.
Versus the first published build it:
- **drops the solver-supplied `uids` / `filledAmount` proof-of-settle** (issues #1, #4) — `wrapperData =
  abi.encode(Loan[])` only; this also removes the INT_MAX-after-`invalidateOrder` false positive and lets
  the order's appData `metadata.wrappers` hint be complete + final so a solver's verbatim chain encoding
  fills. Fill-correctness is enforced by `CoWSafeWrapper` (`filledAmount >= expectedFill`, with a
  `filledBefore == 0` precheck so an invalidated order can't be mistaken for filled there either);
- **adds a trampoline data-integrity guard** (issue #3) — `_wrap` commits `keccak256(ctx)` to transient
  storage; `executeOperation` reverts `ParamsTampered` unless the callback `params` hash matches, so the
  pool can't alter the settlement data while it round-trips through the flash callback (mirrors CoW's
  FlashLoanRouter `pendingDataHash`);
- **routes all token moves through OpenZeppelin v5.5.0 `SafeERC20`** (issue #2) — vendored as a pinned
  submodule (`lib/openzeppelin-contracts` @ v5.5.0), per review feedback to use the standard
  implementation rather than an inlined one. `safeTransfer` / `forceApprove` handle no-data tokens
  (USDT), approve-from-nonzero restrictions, and only accept a no-data success from an address with code.

Superseded staging flash wrappers (do not use): `0xfe98…E4CD` (v5, hand-rolled SafeTransfer instead of
the vendored standard), `0x1Dc6…106f` (v4, SafeTransfer without the code-length check), `0x8dC8…a888`
(v3, trampoline, pre-SafeERC20), `0x4502…6B9f` (interim, twap-built — metadata didn't match this
source), `0x7aC5…785d` (original proof-of-settle build).

## Production cross-network anchors (not yet deployed)

Built against the **production** settlement `0x9008D19f…`. With the same salts these reproduce on every
CoW chain (the flash-wrapper anchor additionally assumes the Aave pool address matches Gnosis'):

| Contract | Address |
|---|---|
| CoWSafeWrapper | `0x80e6793ae895a5a735A1943B36C56baBdFD217e0` |
| CoWSafeSigHandler | `0x36d2BDc057E360C700CF52cF54008A1C192dC0A2` |
| CowFlashLoanWrapper | `0x02a80029E730937d35CE97D240E19C957E82E7d9` |

## Going to production

A wrapper must be **allowlisted as a CoW solver** to call `settle`. Two addresses need allowlisting for
the leverage stack: `CoWSafeWrapper` and `CowFlashLoanWrapper`, plus the relayer/solver address that
calls `wrappedSettle`. Reach out via the [CoW forum](https://forum.cow.fi) / Discord; staging onboarding
is lighter than the production CIP.

## Reproduce an address locally

```bash
forge build
# init code hash = keccak(creationCode ++ abi.encode(args)); address = create2(FACTORY, salt, initCodeHash)
cast create2 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C \
  --salt $(cast format-bytes32-string "CowFlashLoanWrapper.v6") \
  --init-code-hash <keccak of creationCode ++ abi.encode(settlement, pool)>
```
