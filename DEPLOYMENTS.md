# Deployments

All contracts are deployed **deterministically** via the Arachnid CREATE2 factory
`0x4e59b44847b379578588920cA78FbF26c0B4956C` (present at the same address on every chain). The deployed
address is a pure function of `(creation bytecode, constructor args, salt)`, so the same source +
settings reproduce the same address on any network.

- Compiler: solc **0.8.34**, optimizer **200 runs**, `evm_version = cancun` (EIP-1153 transient storage).
- Salts (ascii): `CoWSafeWrapper.v3`, `CoWSafeSigHandler.v3`, `CowFlashLoanWrapper.v2`.
- Constructors: `CoWSafeWrapper(ICowSettlement settlement)`, `CoWSafeSigHandler(address wrapper, address
  settlement)`, `CowFlashLoanWrapper(ICowSettlement settlement, IAavePool pool)`.

## Gnosis Chain (chain id 100) — CoW **staging** settlement

These point at CoW Protocol's **staging/barn** settlement so the stack can be exercised end-to-end before
production allowlisting. All three are **verified on Sourcify (exact match)**.

| Contract | Address |
|---|---|
| **CoWSafeWrapper** | [`0x531636e6e18F3A52c283aCCda39D7185E4597A37`](https://gnosisscan.io/address/0x531636e6e18F3A52c283aCCda39D7185E4597A37) |
| **CoWSafeSigHandler** | [`0x29619484de063A3E06e432a0CCBF5a2BE6F024DC`](https://gnosisscan.io/address/0x29619484de063A3E06e432a0CCBF5a2BE6F024DC) |
| **CowFlashLoanWrapper** | [`0x7aC55b24af85C6F5e866293B38E3ff795CAe785d`](https://gnosisscan.io/address/0x7aC55b24af85C6F5e866293B38E3ff795CAe785d) |

External addresses used:
- CoW staging settlement: `0xf553d092b50bdcbddeD1A99aF2cA29FBE5E2CB13` (authenticator `0x02073540567FA1EABcBf74C2F7E6F9029ca7d800`, vaultRelayer `0xC7242d167563352E2BCA4d71C043fbe542DB8FB2`)
- Aave V3 Pool: `0xb50201558B00496A145fE76f7424749556E326D8`
- CoW **production** settlement (same on all CoW chains): `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`

## Production cross-network anchors (not yet deployed)

Built against the **production** settlement `0x9008D19f…`. With the same salts these reproduce on every
CoW chain (the flash-wrapper anchor additionally assumes the Aave pool address matches Gnosis'):

| Contract | Address |
|---|---|
| CoWSafeWrapper | `0x80e6793ae895a5a735A1943B36C56baBdFD217e0` |
| CoWSafeSigHandler | `0x36d2BDc057E360C700CF52cF54008A1C192dC0A2` |
| CowFlashLoanWrapper | `0xdcd2Ac91fdf3295Af46FffB2F602B93c995232A8` |

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
  --salt $(cast format-bytes32-string "CowFlashLoanWrapper.v2") \
  --init-code-hash <keccak of creationCode ++ abi.encode(settlement, pool)>
```
