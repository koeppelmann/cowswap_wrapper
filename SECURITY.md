# Security model

> Unaudited application code. It builds on the audited Safe v1.3.0, Aave V3, CoW Protocol core, and CoW
> DAO's `CowWrapper` base. The notes below are the design's intended guarantees and the invariants the
> test suite exercises — not a formal audit.

## Trust model at a glance

- **The user** owns the position Safe 1/1 and is the only party that can authorize what may run
  (`registerMetaOrder` is a direct Safe call).
- **Solvers** are CoW-allowlisted; they can *execute* a registered action but can never invent, alter,
  redirect, or skip it. The worst a solver can do is decline to execute (or cause a revert).
- **The settlement** is CoW's canonical `GPv2Settlement`; the **Aave Pool** is canonical and immutable
  in the deployment. Both are trusted as in any integration; the flash wrapper additionally hash-commits
  its callback context (trampoline, below), so it does not rely on the pool passing data through honestly.

Everything happens in one transaction and is **all-or-nothing**: any failure — hash mismatch, pre/post
revert, signature invalid, order not filled, loan not repaid — reverts the entire transaction. No
partial state is ever observable.

## `CoWSafeWrapper` invariants

1. **Owner-only authorization.** `registerMetaOrder` requires `msg.sender == safe` *and* the UID's
   embedded owner == the safe. Because the wrapper is *not* the Safe's fallback handler, this cannot be
   spoofed through the permissionless fallback path.
2. **Exact action.** At settle the solver supplies the pre/post calldata; the wrapper requires
   `keccak(pre) == preHash` and `keccak(post) == postHash`. Only the Safe's pre-committed transactions
   run; CALL or DELEGATECALL operation is part of the hash, so the Safe commits to that too.
3. **No bypass.** The order's EIP-1271 signature returns valid **only** while a transient "bless" flag is
   set — which happens only inside this wrapper's own settlement, between running `pre` and calling
   `settle`. Outside that window the order is unsettleable; a direct `settle` of it reverts.
4. **Proof of fill.** After `settle`, the wrapper requires `filledAmount(uid) ≥ expectedFill`. A solver
   that runs `pre` but omits the trade reverts everything.
5. **One-shot.** A registration is frozen (consumed) before any side effect and cannot be replayed.
6. **No cross-Safe reach.** Each `execTransactionFromModule(safe, tx)` requires `safe`'s *own* registration
   whose hash matches `tx`; one Safe's action can never execute on another Safe.
7. **Final-wrapper-only.** It requires an empty `remainingWrapperData`, so the bless window covers only
   the direct `settle` call (it still composes *behind* `CowFlashLoanWrapper`).

## `CowFlashLoanWrapper` invariants

1. **Trampoline data integrity (no injected settlement).** `wrapperData = abi.encode(Loan[])` only —
   no solver-supplied order UIDs. Before borrowing, `_wrap` commits `keccak256` of the full context
   (settle calldata + the rest of the chain + the loan-delivery plan) to transient storage; the Aave
   callback re-hashes the `params` it is handed and reverts (`ParamsTampered`) on any mismatch. So the
   settlement can ONLY be driven by the exact bytes the solver passed to `wrappedSettle` — a
   malicious/upgraded pool cannot substitute the settle calldata or redirect loan delivery. The terminal
   hop is additionally constrained to the `settle()` selector. This mirrors CoW's audited FlashLoanRouter
   (`pendingDataHash`). Keeping `wrapperData` UID-free also makes it complete and final inside an order's
   appData `metadata.wrappers`, so a wrapper-aware solver's verbatim chain encoding fills correctly.
2. **Callback authenticity.** `executeOperation` requires `msg.sender == Pool`, `initiator == this` (a
   third-party-initiated loan with this contract as receiver reverts), and an in-flight transient flag.
3. **Atomic repayment / statelessness.** No owner, no registry; it holds no funds between transactions.
   The chain must route `amount + premium` back before the callback returns or Aave's pull reverts the
   whole transaction. Delivery and repayment use the context the wrapper itself committed; only the
   per-asset premium comes from the pool.
4. **No nesting of itself** (transient guard) and **no duplicate loan assets** (rejected) keep the
   accounting unambiguous.
5. **Fill-correctness is not this layer's job.** The flash wrapper is a generic liquidity primitive and
   deliberately does NOT verify that the downstream filled anything (a downstream that repays the loan
   and returns the magic value succeeds at this layer). The user's order is still protected: when the
   chain ends in `CoWSafeWrapper`, that wrapper independently enforces `filledAmount >= expectedFill`, so
   no fill can be faked on a user's Safe.

> Do **not** send tokens to `CowFlashLoanWrapper` — it is stateless with no recovery path; stray tokens
> are inert (they cannot subsidize a repayment and cannot be swept).

## Known assumptions / limitations

- **ERC-20 compatibility.** Delivery and repayment go through OpenZeppelin v5.5.0 `SafeERC20`
  (`safeTransfer` / `forceApprove`, vendored as a pinned submodule): non-standard tokens that return no
  data (e.g. USDT) and approve-from-nonzero restrictions are handled, and a no-data success is only
  accepted from an address with code. Fee-on-transfer and rebasing tokens remain out of scope (the
  loan-accounting assumes the delivered/repaid amount equals the requested amount).
- **Canonical Aave pool / CoW settlement.** The immutable `POOL` and `SETTLEMENT` addresses are assumed
  canonical. The flash wrapper's trampoline binding means even a misbehaving pool cannot substitute the
  settle calldata or redirect delivery (the callback `params` are hash-checked), but a maliciously-upgraded
  pool proxy is otherwise outside the threat model, as for any flash integration.

## How these are tested

`forge test` (Gnosis fork) covers, against the real settlement + Aave pool:

- happy paths: meta-order swap with enforced pre/post; full leverage open & close via the two-wrapper chain;
- multi-order / multi-Safe batches;
- adversarial negatives: non-solver caller, unregistered/duplicate/replayed nonce, tampered pre/post,
  direct-`settle` bypass, EIP-1271 outside the window, non-final-wrapper chaining, third-party flash
  callback, direct `executeOperation`, unrepaid loan, and a fake downstream that returns the magic value
  without settling (which succeeds at the flash layer by design — fill is enforced by `CoWSafeWrapper`).

## Reporting

Found an issue? Please open a private report to the repository owner before public disclosure.
