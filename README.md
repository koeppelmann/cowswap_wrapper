# CoW Protocol wrappers: enforced Safe meta-orders & flash loans

Two small, general-purpose [CoW Protocol](https://docs.cow.fi) **settlement wrappers** — contracts that
wrap `GPv2Settlement.settle` and *enforce* logic around a swap that ordinary hooks cannot:

| Contract | What it does |
|---|---|
| **`CoWSafeWrapper`** | Lets a [Safe](https://safe.global) attach an **enforced pre-transaction and post-transaction** to one of its CoW orders. The order can only settle if the Safe's own, pre-committed pre/post run around it — atomically, or not at all. |
| **`CowFlashLoanWrapper`** | Wraps any downstream wrapper chain in an **Aave V3 flash loan**, so the borrowed liquidity is available *during* the settlement. A transient hash commitment (trampoline) guarantees the settlement can only run with the exact bytes the solver passed in — the pool cannot tamper with the data in flight. |

They are standard [`ICowWrapper`](src/CowWrapper.sol)s and **compose**: chain
`CowFlashLoanWrapper → CoWSafeWrapper → settle` and you get flash-loan-powered, atomically-enforced
Safe actions around a CoW swap. The canonical example is **leverage** (flash-borrow → swap → supply +
borrow on a money market → repay), shown end-to-end in [`test/LeverageExample.t.sol`](test/LeverageExample.t.sol) —
but nothing in either contract is leverage- or even Aave-specific beyond the flash source.

> **Status:** unaudited application code built on the audited Safe, Aave V3, CoW Protocol, and CoW DAO's
> `CowWrapper` base. Verified end-to-end on a Gnosis mainnet fork against the *real* settlement and Aave
> pool (21 tests). Using a wrapper in production requires CoW DAO to allowlist it as a solver.

---

## Why wrappers (vs. hooks)

CoW pre/post **hooks** (via the shared `HooksTrampoline`) are *best-effort and permissionless*: a solver
can skip them, and because the trampoline is shared, anyone's order can call your hook targets. A
**wrapper** is a contract on CoW's solver allowlist that wraps `settle`; an order routed through it
**cannot settle at all** unless the wrapper's logic runs and verifies. That turns "best-effort hook"
into "enforced invariant."

CoW DAO ships a tiny abstract base, [`CowWrapper`](src/CowWrapper.sol), that handles solver
authentication, **chaining** several wrappers, and a magic-value return. Both contracts here inherit it
and implement only their own `_wrap` logic.

---

## `CoWSafeWrapper` — enforced Safe pre/post around a CoW order

A position lives in a dedicated **Safe** that the user owns 1/1. The wrapper is enabled as a Safe
**module** (so it can act *as* the Safe) and is the CoW solver that wraps `settle`. A companion
fallback handler, **`CoWSafeSigHandler`**, answers the order's EIP-1271 check.

**Setup (per Safe, once):** enable `CoWSafeWrapper` as a module, set `CoWSafeSigHandler` as the fallback
handler.

**Per action:**
1. Build a CoW order whose `appData` carries the wrapper chain in CoW's native **`metadata.wrappers`**
   field — `[{address: wrapper, data}, …]` with the exact `OrderExec[]` (safe, nonce, full pre/post
   calldata) as `data`. The order UID commits to it, the orderbook serves it, and CoW's driver encodes
   the solver's `wrappedSettle` call from it **verbatim** — so any wrapper-aware solver can fill the
   order with zero custom integration.
2. The Safe calls `registerMetaOrder(nonce, {uid, expectedFill, preHash, postHash, notBefore, deadline})`
   — a **direct Safe call** (msg.sender == the Safe), storing only the **hashes** of the pre/post txs.

**At settle**, a solver calls `wrappedSettle(settleData, abi.encode(OrderExec[]))`, supplying the actual
pre/post calldata. The wrapper, in one atomic transaction:
- verifies `keccak(pre) == preHash` and `keccak(post) == postHash`, then freezes the registration (one-shot);
- runs **pre** as the Safe;
- sets a transient "bless" flag and calls `settle`; the settlement's EIP-1271 check returns valid **only
  while blessed** (so the order is unsettleable outside this flow — no bypass);
- requires `filledAmount(uid) ≥ expectedFill` (the trade really happened);
- runs **post** as the Safe.

Any failure anywhere reverts the entire transaction. See
[docs/cowsafewrapper-flow.svg](docs/cowsafewrapper-flow.svg).

**Key properties**
- *Owner-only authorization* — only the Safe can register (`registerMetaOrder` requires `msg.sender ==
  safe` and the UID owner == the Safe). A solver can only execute a registration; never invent or alter one.
- *No bypass* — the order's signature is valid only during the wrapper's own settlement; a direct
  `settle` of the order fails.
- *Hashes on-chain, calldata off-chain* — registration is cheap; the executable pre/post ride in the
  order's appData and are hash-checked at settle.
- *Pre/post are full Safe transactions* — CALL or DELEGATECALL (e.g. batching via `MultiSendCallOnly`),
  committed by the Safe via the hash.
- *Final-wrapper-only* — to keep the bless window tight, `CoWSafeWrapper` must be the last wrapper
  before `settle` (it still composes *behind* `CowFlashLoanWrapper`).

## `CowFlashLoanWrapper` — flash liquidity around a settlement

Placed **first** in a chain, it takes an Aave V3 flash loan, delivers it to the declared recipients, and
runs the rest of the chain (→ `CoWSafeWrapper` → `settle`) **inside the loan window**, then repays from
its own balance when the chain returns. See [docs/cowflashwrapper-entry.svg](docs/cowflashwrapper-entry.svg).

`wrapperData = abi.encode(Loan[] loans)` — which tokens/amounts to flash-borrow and where to deliver
them. Nothing else: keeping it free of order UIDs makes it fully deterministic, so it can sit **complete
and final** in the order's appData `metadata.wrappers` (a UID can't embed itself — it commits to the
appData).

**Trampoline data integrity.** Before borrowing, `_wrap` commits `keccak256` of the full context (settle
calldata + the rest of the chain + the delivery plan) to transient storage; the Aave callback re-hashes
the `params` it is handed and reverts (`ParamsTampered`) on any mismatch — mirroring CoW's audited
`FlashLoanRouter`. So even a malicious/upgraded pool cannot substitute the settlement or redirect
delivery. The flash layer deliberately does **not** verify fills (that's `CoWSafeWrapper`'s job —
`filledAmount ≥ expectedFill`); it is otherwise self-securing: **no owner, no registry, holds no funds
between transactions** — a loan that can't be repaid simply reverts the whole transaction. Token moves go
through OpenZeppelin v5.5.0 `SafeERC20` (vendored), so USDT-style tokens work.

**Callback safety:** `executeOperation` requires `msg.sender == Pool`, `initiator == this` (so a
third-party-initiated loan with this contract as receiver reverts), the in-flight transient flag, and the
trampoline hash match.

---

## Composition & the leverage example

```
solver
└─ CowFlashLoanWrapper.wrappedSettle(settleData, chain)        # chain = [Loan[]][CoWSafeWrapper][OrderExec[]]
   └─ Aave flashLoan → executeOperation                         # the loan window
        ├─ deliver borrowed tokens to the Safe
        ├─ CoWSafeWrapper.wrappedSettle(settleData, OrderExec[])
        │    ├─ verify hashes · freeze · run PRE as the Safe
        │    ├─ bless · GPv2Settlement.settle(settleData) · prove fill
        │    └─ run POST as the Safe   (routes loan+premium back to the flash wrapper)
        └─ require loan+premium routed back · approve repayment
   Aave pulls loan + premium
```

**Leverage** (`test/LeverageExample.t.sol`), 2× long on a Gnosis fork:
- *Open:* flash-borrow the debt token, the order sells it (plus equity) for collateral, the **post**
  supplies collateral + borrows the debt + repays the flash. End state: a leveraged money-market
  position, zero dust, flash repaid to the wei.
- *Close:* the **pre** repays debt + withdraws collateral, the order sells collateral for the debt token,
  the **post** repays the flash and the equity remains in the Safe.

Both directions, plus the adversarial negatives (unrepaid loan, third-party callback, tampered post,
direct-settle bypass, direct `executeOperation`), run green against real Aave V3 + real `GPv2Settlement`.

---

## Build & test

```bash
forge build
GNOSIS_RPC=https://rpc.gnosischain.com forge test           # fork tests need a Gnosis RPC
```

## Deployments

See [DEPLOYMENTS.md](DEPLOYMENTS.md). Live on **Gnosis** (CoW staging settlement), Sourcify-verified,
deployed deterministically (same address on any chain via the Arachnid CREATE2 factory).

## Layout

```
src/
  CowWrapper.sol          # CoW DAO base (vendored): solver auth, chaining, magic value
  CoWSafeWrapper.sol      # enforced Safe pre/post meta-orders
  CoWSafeSigHandler.sol   # Safe fallback handler — EIP-1271 for CoWSafeWrapper
  CoWSafeSigHandlerSim.sol# handler variant: +simulation-only validity (tx.gasprice == 0) → native eip1271 submission
  CowFlashLoanWrapper.sol # Aave V3 flash-loan layer (trampoline-committed callback)
test/
  CoWSafeWrapper.t.sol    # the meta-order wrapper, standalone
  CoWSafeSigHandlerSim.t.sol # unit tests for the simulation-validity branch
  LeverageExample.t.sol   # both wrappers composed → leverage open/close (the example)
  helpers/SafeModuleSetup.sol
docs/                     # sequence diagrams (svg + png)
```

## License

MIT for the wrappers in `src/` (except `CowWrapper.sol`, which is CoW DAO's, MIT OR Apache-2.0).
