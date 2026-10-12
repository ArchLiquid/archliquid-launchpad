# Validate a fresh V4 release

The deployment script and liquidity canary are restricted to Robinhood testnet
(chain ID 46630). The canary targets an explicit factory rather than the
historical release addresses in the README. Production contract constructors,
entry points and dependency commits are unchanged.

## Deployment preflight

Before recording deployment transactions, `DeployV4UserLiquidity` checks that
the stock registry has a deployed stock swap executor. An unset executor would
otherwise allow the release family to deploy but make token creation fail.

It also checks that PositionManager, StateView and the locker/router refer to
the same deployed PoolManager, and that PositionManager uses the selected
Permit2. A coherent configuration is necessary for release validation; getter
consistency does not establish that arbitrary supplied contracts are trusted.
Use the reviewed, source-verified dependencies from the release manifest.
The deployment script records a sequence of transactions; its final release
checks do not turn that sequence into one atomic on-chain operation.

## Select the canary target

Set these variables to the new release's factory and an approved stock token:

| Variable | Required | Meaning |
|---|---|---|
| `TESTNET_V4_TOKEN_FACTORY` | Yes | Fresh factory emitted by the deployment script. |
| `TESTNET_AMM_STOCK` | Yes | Code-bearing stock approved by that factory's registry. |
| `TESTNET_V4_CANARY_MAX_FACTORY_FEE` | No | Maximum acceptable factory fee, in wei. Defaults to 1000000000000000 (0.001 ETH); may be lowered, never raised above that ceiling. |
| `PRIVATE_KEY` | Yes for the script | Local testnet signer used by the existing script workflow. Keep it outside version control and command history. |

Direct deployments of `V4UserLiquidityCanary` pass
`(provider, factory, stock, maximumFactoryFee)`; its public result identifiers
keep their existing names.

No historical factory or stock fallback is used. The canary derives the adapter,
provisioner, WETH, locker, PositionManager, StateView and Permit2 from the target,
then checks their reciprocal bindings and immutable identities. It also checks
stock approval, the stock executor and the adapter's locker fee exemption.
The factory must have zero previously created direct tokens; a successful
canary consumes that one-time freshness condition.

Each of the two liquidity positions uses 100,000 canary token units (18
decimals) and 0.001 ETH. The transaction value is the target factory's actual
fee plus 0.002 ETH. Its hard ceiling is 0.003 ETH, excluding transaction gas.
A lower configured fee maximum provides a tighter limit. The signer must also
retain the script's gas balance reserve.

## Simulate before broadcasting

From a checkout with its pinned dependencies, run the script without
`--broadcast`:

```bash
forge script script/CanaryV4UserLiquidity.s.sol:CanaryV4UserLiquidity \
  --rpc-url https://rpc.testnet.chain.robinhood.com
```

[Foundry treats this as a dry run](https://getfoundry.sh/guides/scripting-with-config/).
Review the target factory, stock, signer, exact transaction value and simulated
postconditions before separately authorizing any broadcast. This repository's
local validation does not publish a release or send testnet transactions.

The constructor repeats the preflight checks at execution time. Token
creation, the timed position and the permanent position occur in one
transaction; a failed check reverts them together. It verifies canonical pool
identity, positive position liquidity, NFT custody, timed lock ownership and
metadata, approval cleanup and asset accounting. The timed lock is transferred
to the provider and the permanent NFT goes to `DEAD`.

Unused ETH and remaining canary tokens return to the provider. Preexisting WETH
donations to the adapter or provisioner must remain unchanged; they do not make
an otherwise valid canary fail. This validates integration and wiring, rather
than replacing source verification, economic review or an independent audit.
The canary exercises token creation and liquidity custody. Trading and stock
dividend distributions require their own integration tests; a generic stock
executor may support approved stocks beyond the router's direct stock route.

## Repeat local checks

```bash
forge fmt --check
forge test --no-match-path 'test/*Fork.t.sol' -vv
forge build --sizes

# Read-only tests against a fresh available Robinhood snapshot
forge test --match-path 'test/*Fork.t.sol' \
  --fork-url https://rpc.testnet.chain.robinhood.com \
  --fork-block-number <fresh-block> -vv
```

Use chain ID 46630 and record the selected block with the test results. Public
RPC endpoints may prune historical state; use a fresh block or an archival
endpoint for an older snapshot. Fork tests use fixture accounts and do not
need a real signing key.

## Validation of this change

Validated on 12 October 2026 against upstream main
`bda6629e5d178b588e7c100eae776fae6ac10d09`, using Foundry 1.8.5 and
Solidity 0.8.30 with the repository's existing compiler settings.

- 87 offline tests passed without failures or skips. Both fuzz properties ran
  1024 cases. The change adds 61 offline tests.
- All 10 V4 fork integration tests passed without skips on chain 46630 at block
  133728522. Four new canary cases cover dynamic fees and donations, another
  approved stock through the generic executor, repeated-use rejection and
  rollback after both positions have been created.
- Formatting, diff checks and deployable runtime/initcode size checks passed.
- Production source, public contract APIs and all five dependency pins are
  unchanged. Solidity files use LF through `.gitattributes` so Windows and Linux
  run the same formatting checks.

The change is independent of the earlier launch-safety PR. No on-chain
transaction was signed or broadcast during validation.
