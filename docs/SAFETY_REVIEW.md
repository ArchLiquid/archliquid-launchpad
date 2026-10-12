# Launchpad safety improvement review

Review date: 12 October 2026.
Base: main at bda6629e5d178b588e7c100eae776fae6ac10d09.
Feature branch: feature/launchpad-safety-and-usability.

This change gives contributors an exit from failed presale settlement, adds
explicit user execution bounds, verifies actual asset consumption and position
custody, and repairs price-limited V4 swaps. Existing constructor tuples and ABI
entries are preserved. The precise lifecycle and economic changes are described
in [LAUNCH_SAFETY.md](LAUNCH_SAFETY.md).

## Prioritised fixes and evidence

| Priority | Finding | Impact / severity | Effort / change risk | Evidence and resulting behavior |
|---|---|---|---|---|
| 1 | Successful presales could remain non-refundable when finalization repeatedly reverted. | High fund availability risk. | Medium; intentional lifecycle boundary. | Original V3 and adapter cancellation rejected after soft cap. [Both presales](../src/ArchPresale.sol) now close finalization at END+7days and allow permissionless cancellation and full caller-owned refunds. [Presale regressions](../test/PresaleSafety.t.sol) cover external failure, exact boundary, custody failure and refund rollback. |
| 2 | A price-limited V4 swap prepaid input but left unused currency credit unsettled. | Medium; valid user swaps reverted atomically. | Small; input settlement policy. | Original credit-accounting regression failed with CurrencyNotSettled. [Router](../src/ArchV4SwapRouterAdapter.sol) now validates consumed input and returns unused credit to its payer. [Offline tests](../test/V4SwapSafety.t.sol) and [real V4 fork](../test/ArchV4LaunchLiquidityAdapterFork.t.sol) cover partial fills, taxes and net output minimums. |
| 3 | Mint/seed return values could leave unused assets/allowances or be mistaken for claim-safe dust. | Medium reliability and integration risk. | Medium; accounting and event-value semantics. | Original V3 partial-consumption fixture left WETH stranded; a false adapter token report could burn claim allocations. [Presales](../src/ArchAdapterPresale.sol) and [curves](../src/ArchBondingCurve.sol) verify observed balance changes, clear approvals and settle only tracked LP leftovers. Fixtures model adverse accounting, not typical canonical rounding. |
| 4 | Contract wallets rejecting ETH could not use the legacy refund; tiny initial contributions could have zero entitlement. | Medium integration risk. | Small; additive routing and stricter input acceptance. | Both original presales accepted zero-entitlement contributions. New refundTo spends only the caller's contribution, retains legacy refund logs and adds routed-recipient metadata. Receiver reentry/failure, zero recipient, split-wallet claim solvency and team allocations are tested. |
| 5 | Exact-threshold V4 graduation could reach its rounded terminal reserve early, making the final zero-output buy revert. | Medium launch availability risk. | Medium; explicit new funding operation. | Original runtime regression reached target−1, quoted zero output and rejected the ordinary buy. [Adapter curve](../src/ArchAdapterBondingCurve.sol) adds exact-value, deadline-bound completion after prior funding. The [real-fork regression](../test/ArchAdapterLaunchpadV4Fork.t.sol) graduates the terminal plateau into a permanent V4 position. |
| 6 | Donated curve tokens changed the graduation seed, and could exceed an otherwise validated V4 input capacity. | Medium; source-derived availability/economic risk. | Medium; deliberate donation policy. | The original seed used token.balanceOf(curve), while preflight validated accounted terminal inventory. Both curves now seed tokenReserve+LP_SUPPLY and send excess donations to DEAD. [Regressions](../test/CurveSafety.t.sol) cover u128 seed capacity, donation invariance, partial consumption and preserved WETH donations. |
| 7 | Trades/liquidity lacked user expiry; liquidity had no caller minimum minted liquidity or consumed input. | High integration value; protective mechanism. | Medium; additive APIs. | New deadline trade variants and addLiquidityWithLimits retain legacy entry points. [V4 tests](../test/V4LiquiditySafety.t.sol) enforce expiry before custody, actual consumption, inclusive minimum liquidity and atomic refunds. Live tests use the new entry point for timed and permanent positions. |
| 8 | Dependency and minted-position identities were not cross-checked. | Medium misconfiguration risk; no live exploit asserted. | Small; tighter deployment/mint acceptance. | The original wrong-StateView, wrong-Permit2 and wrong-NFT-key regressions failed. [Adapter](../src/ArchV4LaunchLiquidityAdapter.sol) and [provisioner](../src/ArchV4UserLiquidityProvisioner.sol) now verify manager relationships, canonical pool key, real liquidity, custody and timed lock metadata. Actual deployed getter ABI and real-fork execution were checked. |
| 9 | Unusable one-unit/exact-target curve configurations could be accepted. | Low; unusable launch creation, without accepted purchase funds. | Small; stricter preflight. | V3 rejects curveSupply1 while preserving productive above-target purchases; V4 rejects no productive range within its exact threshold. Dedicated regressions cover both cases. |

## Validation

The final checks use Foundry 1.8.5, Solidity 0.8.30, Cancun, optimizer 200 and via IR,
with all five original dependency commits unchanged.

- 108 offline tests passed, with no failures or skips.
- Seven fuzz properties ran 1024 cases each; the stateful invariant ran 128 sequences
  and 8192 handler calls, checking reserve solvency, inventory and permanent custody.
- Seven integration tests passed without skips on Robinhood chain 46630 at
  block 133709081. No transaction was signed or broadcast. Coverage includes
  live V4 mint/lock, presale/curve graduation,
  user limits, hostile starting price, partial swaps, taxes and distributions.
- All 306 original ABI entries across 13 contracts were preserved, including
  constructors, parameter/return types, event signatures and mutability.
- Formatting and deployable runtime/initcode size checks passed. The largest
  changed child deployer has 1943 runtime bytes of remaining limit.
- Static warnings were reviewed: caller-owned refund destinations, guarded
  callbacks/events, exact balance/identity checks, checked casts and block-time
  deadlines are intentional. The salt is explicitly public, not a security
  randomness guarantee. The build is not claimed to be warning-free.

CI pins its action commits and Foundry release, runs offline regressions/fuzz/
invariants and size checks on PRs and feature pushes, and provides an optional
manual read-only fork step that records a fresh available block. The public RPC
may prune historical state; use a fresh snapshot or an archival endpoint when
repeating an older block.

## Release decisions and further improvements

These source fixes require a new deployment; the existing published contracts
are immutable. Review the seven-day presale window, donation disposal, actual
seeded-amount events and explicit zero-token completion before approving a
release. Completion can involve substantial ETH for coarse token units; an
integration must show the entire payable amount and obtain a separate decision,
rather than automatically retry a normal buy through this function.

An independent contract audit and verified deployment manifest remain release
gates. Public pre-initialization can still deny curve graduation; the price
guard protects the seed and pre-graduation holders retain their sell path.
Dependency code, approved stock routes, chain behavior and liquidity economics
remain part of the trust model. Absolute breach-free security is not established
by local tests or a fork.

Potential follow-up improvements, not verified defects: consolidate duplicated
pure accounting helpers without changing the public structs; add versioned ABI
snapshots to release automation; and provide transaction-preview/countdown UI
using the new boundaries. Those require separate review and should not be
confused with the verified fixes above.
