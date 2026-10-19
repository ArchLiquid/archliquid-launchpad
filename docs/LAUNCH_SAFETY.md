# Launch safety and integration guide

These protections apply to contracts compiled and deployed from this revision.
The published August 2026 testnet contracts are immutable and do not acquire
new entry points when this repository changes.

## Presale lifecycle

Both presale families retain their existing constructor configuration and
contribute(), finalize(), cancel(), claim() and refund() entry points.

A sale may finalize after its end, or earlier once its hard cap is reached,
provided the soft cap is met and block.timestamp < finalizationDeadline().
The deadline is END + FINALIZATION_GRACE_PERIOD, with a fixed seven-day grace
period. At the exact deadline, finalization is closed and anyone may cancel an
unfinalized sale, including one that reached its soft cap. Below-soft-cap sales
can still be canceled as soon as END is reached.

This gives contributors a predictable exit when a router, position manager,
locker, treasury or other finalization dependency repeatedly reverts. No
administrator can move the deadline or redirect refunds. A finalized sale
cannot subsequently cancel or refund.

A participant flow is:

1. Read START, END, HARD_CAP, totalRaised, per-wallet limits and
   quoteContribution(amount).
2. Contribute during the sale window. An initial contribution must produce
   at least one token base unit; later top-ups use the caller's accumulated
   entitlement. The quote describes a standalone amount and uses the same
   floor rounding as claims.
3. If finalized, claim the caller's allocation.
4. If the soft cap was missed, or finalizationDeadline() has arrived without
   finalization, call cancel(), then refund().

Contract wallets that reject native ETH can call refundTo(payableRecipient).
Only the caller's recorded contribution is spent; naming a recipient does not
grant access to that recipient's balance. A rejected transfer reverts the
entire refund, preserving the claim. Refunded continues to identify the
contributor; RefundRouted additionally identifies a different recipient.

Cancellation and refunds are permissionless, so applications can offer a
clear countdown and recovery action without relying on the creator.

## Curve execution and graduation

Prefer buyWithDeadline(minTokensOut, deadline) and
sellWithDeadline(tokensIn, minEthOut, deadline) when submitting user trades.
Deadlines are inclusive: the transaction may execute at the given timestamp
but cannot execute afterward. The original buy and sell entry points remain
available and retain their minimum-output behavior.

V4 graduation cannot overshoot its target. Read graduationBuyAmount() for the
exact gross ETH remaining after the floor-rounded 1% trade fee. If the final
rounded token reserve has already been reached, quoteBuy() can return zero
tokens for that remaining payment. Ordinary buy still rejects zero output.

The separate completeGraduation(deadline) entry point explicitly opts into
funding that remaining amount without receiving tokens. It accepts only the
exact remaining payment and only when the current token reserve already
equals the terminal rounded reserve. Show the user the amount, fee and
zero-token result before requesting a signature. A failed seed rolls back
the payment, fee, reserve updates and position creation together.

The remaining amount can be substantial for a supply with very few token base
units. This is voluntary funding, not a normal token purchase: never select
completion automatically after a failed buy. Require a separate, explicit user
decision based on the current full payable amount and zero tokens received.
Completion requires prior successful funding. New V4 curves reject configurations
with no productive buy range; V3 rejects a one-base-unit curve allocation.

Both curve families seed their accounted remaining inventory, rather than
letting token donations change the graduation price. Excess donated tokens
are sent to DEAD at graduation. Donating tokens is not a contribution,
purchase or refundable deposit.

## Bounded V4 user liquidity

Use addLiquidityWithLimits() for new integrations. It keeps the existing
fixed hookless pool, inclusive price corridor and position custody policy,
and adds caller-controlled execution bounds:

    ArchV4UserLiquidityProvisioner.LiquidityLimits({
        deadline: deadline,
        minTokenUsed: minimumTokenConsumption,
        minWethUsed: minimumWethConsumption,
        minLiquidity: minimumMintedLiquidity
    })

The deadline is checked before input transfers. The transaction reverts
atomically if actual consumption or minted liquidity falls below a bound.
Unused inputs are returned to the provider; existing provisioner balances
cannot be included in a refund. A rejecting ETH receiver causes the whole
addition to revert.

minLiquidity uses Uniswap position-liquidity units, not token or ETH units.
Calculate it for the intended full-range position and current pool price.
A price corridor limits the execution price; minimum input consumption alone
does not guarantee a useful amount of liquidity.

The original addLiquidity() remains available with its original arguments.
It uses no expiry or caller minimum-consumption/liquidity limits. Applications
should choose the new entry point to obtain these additional protections.

The adapter verifies that StateView and PositionManager use the same
PoolManager and that PositionManager uses the configured Permit2. After
minting, it checks the NFT's exact pool key, custody and positive liquidity.

## Settlement and price-limited swaps

V3 minting now validates reported amounts against observed balance changes,
clears approvals, burns only unused LP tokens and unwraps unused LP WETH to
the immutable treasury. Contributor and team allocations remain held for
their existing claims. Finalization/graduation events report actual seeded
amounts rather than desired amounts where those differ.

V4 swaps refund unconsumed settled input directly to the original payer,
including when a price limit stops the swap early. Refunds never go to the
output recipient merely because that recipient was selected for the trade.
Minimum output is still checked against the recipient's actual net token
balance increase. Transfer-tax tokens may also tax an input refund; this is
the token's policy and does not create an additional router fee.

## Compatibility and remaining trust assumptions

Existing function selectors, event signatures and constructor tuples are kept.
New functions and events are additive. Finalization now closes after the
seven-day grace period; zero-entitlement initial contributions and unusable
curve configurations are rejected. V3 seeded-amount events report actual
consumption. Donated curve tokens go to DEAD at graduation; ERC20 totalSupply
does not decrease. These economic and lifecycle changes apply to new deployments.

The new WETH-only receive handlers mean Solidity code casting an address to
ArchPresale or ArchBondingCurve must use a payable address cast. The wallet/API
encoding of preserved functions is unchanged.

The fixed infrastructure must still be reviewed and bound correctly. A hostile
pre-initialized launch pool can block graduation; the price guard reverts that
transaction rather than seed at the wrong price, and pre-graduation curve
holders retain their sell path. Presales have the separate timeout refund exit.
Mint accounting validates actual consumption; it does not impose a new maximum
percentage of unconsumed inputs. Avoid treating any test fixture's partial fill
as a prediction of typical Uniswap rounding.

## Review and release checks

Use Foundry v1.8.5, Solidity 0.8.30 and the committed submodule revisions:

    git submodule update --init lib/core lib/lockers lib/token \
      lib/forge-std lib/openzeppelin-contracts
    forge fmt --check
    forge test --no-match-path 'test/*Fork.t.sol' -vv
    forge build --sizes

For a read-only integration fork, first verify chain ID 46630 and the expected
PositionManager code, record a block number, then run:

    forge test --match-path 'test/*Fork.t.sol' \
      --fork-url https://rpc.testnet.chain.robinhood.com \
      --fork-block-number RECORDED_BLOCK -vv

The default CI runs offline regressions, fuzz tests, invariant tests and size
checks with pinned action commits and a pinned Foundry release. Its optional
manual fork step records one testnet block before executing the integration
suites. No private key, signed transaction or broadcast is required.

Before a release, review the constructor bindings, published manifest, code
sizes and verification artifacts, and arrange an independent contract audit.
The external dependencies, chain, compiler, stock route, token policy and
liquidity economics remain part of the trust model; tests cannot establish a
zero-risk security guarantee.
