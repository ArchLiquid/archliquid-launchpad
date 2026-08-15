# ArchLiquid Launchpad

Fixed-price presales and constant-product bonding curves that graduate into
locked Uniswap V3 or V4 liquidity on Robinhood Chain.

> **Status:** Live on Robinhood Chain testnet. Testnet assets have no monetary
> value. Review the contract, network, and transaction details before signing.

## What is included

| Contract | Purpose |
|---|---|
| [`ArchLaunchpad`](src/ArchLaunchpad.sol) | V3 launch factory for approved stock tokens, fixed listing fees, presales, and curves. |
| [`ArchPresale`](src/ArchPresale.sol) | Escrows fixed-price contributions, handles refunds, seeds V3 liquidity, locks the position, and vests the team allocation. |
| [`ArchBondingCurve`](src/ArchBondingCurve.sol) | Buys and sells against virtual reserves, then graduates the remaining inventory into V3 liquidity. |
| [`ArchAdapterLaunchpad`](src/ArchAdapterLaunchpad.sol) | V4 launch factory bound to one liquidity adapter and one tax-aware swap route. |
| [`ArchAdapterPresale`](src/ArchAdapterPresale.sol) | AMM-neutral presale that delegates pool creation and custody to its pinned adapter. |
| [`ArchAdapterBondingCurve`](src/ArchAdapterBondingCurve.sol) | AMM-neutral curve that graduates through its pinned adapter. |
| [`ArchV4LaunchLiquidityAdapter`](src/ArchV4LaunchLiquidityAdapter.sol) | Seeds a hookless, static-fee, full-range V4 position and locks or permanently sends its position NFT. |
| [`ArchV4UserLiquidityProvisioner`](src/ArchV4UserLiquidityProvisioner.sol) | Adds V4 liquidity through the fixed hookless pool key with explicit execution-price bounds and locked-or-burned custody. |
| [`ArchV2SwapRouterAdapter`](src/ArchV2SwapRouterAdapter.sol) | Maintained testnet compatibility route for the stock/WETH leg used by the active V4 tax-distribution path; it is not a V2 launch family. |
| [`ArchV4SwapRouterAdapter`](src/ArchV4SwapRouterAdapter.sol) | Routes launch-token swaps through V4 and stock-token distribution through the configured V2 stock route. |
| [`ArchPresaleDeployer`](src/ArchPresaleDeployer.sol) | Restricts presale deployment to its configured launchpad. |
| [`ArchCurveDeployer`](src/ArchCurveDeployer.sol) | Restricts curve deployment to its configured launchpad. |
| [`ArchTokenDeployLib`](src/lib/ArchTokenDeployLib.sol) | Shared creation helper for wiring the fixed-supply token inside a launch. |

## Launch paths

```text
V3 or V4 launchpad
  │
  ├── fixed-price presale
  │     contributions ──> soft/hard cap decision
  │                           ├── missed ──> full contributor refunds
  │                           └── reached ──> liquidity position locked
  │                                          + contributor claims
  │                                          + team token vesting
  │
  └── bonding curve
        buys/sells against virtual reserves
                    │ reaches graduation threshold
                    v
             remaining tokens + ETH ──> permanent liquidity position
```

Each launch is a separate contract with immutable configuration. V4 launch
accounting uses `ArchAdapterPresale` and `ArchAdapterBondingCurve`; it cannot
choose an AMM at runtime. Each factory is permanently wired to its adapter,
router, locker, WETH, stock registry, and child deployers.

## Robinhood Chain testnet release

Release `robinhood-testnet-v4-user-liquidity-2026-08-15-r1` is active on chain
ID `46630` and uses the live Robinhood testnet V4 stack.

| Component | V4 address |
|---|---|
| Launchpad | `0x45f7497ff12De39924905d9820A2E1CC60707302` |
| Token factory | `0x897cd8ac993184d6dd3B549A5FbEc04f697C107c` |
| Liquidity adapter | `0x7694D631107fea145d872A6003f40a2021F99343` |
| User-liquidity provisioner | `0xba8cB9EE1Ea1126535C22d13805ec5cC22613775` |
| Presale deployer | `0x873d07CD525F447BaC22607c6f535347e354f333` |
| Curve deployer | `0x62FF5dB0062c39B6bc555CD745b1B4E1729f361F` |
| Position locker | `0x8A1bC51e25b8799a5da57ff55f0262A405Ed2b98` |

The V4 PoolManager is `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
The signed release manifest and the complete address set live in the
[integration contracts repository](https://github.com/ArchLiquid/archliquid-contracts).

## AMM-specific guarantees

The adapter boundary keeps launch accounting identical while enforcing the
rules of the selected AMM:

- V3 uses the original launch contracts and validates the deterministic pool's
  initial price before minting its full-range NFT.
- V4 allows only hookless pools with a fixed 0.30% fee and tick spacing 60. It
  verifies the exact intended starting price through `StateView`, mints a
  full-range position through `PositionManager`, and leaves no adapter residue.
  Existing-pool additions use the live `StateView` price only when it remains
  inside the provider's explicit square-root-price corridor; deferred first
  pools must still initialize at the exact deposit-derived price.
- The adapter authorizes only its once-bound token factory, child contracts
  recorded by its once-bound launchpad, and one once-bound provisioner. Users
  cannot call `seed` directly or substitute a router, market, or recipient.

The common boundary is intentionally small:

```solidity
IArchLaunchLiquidityAdapter.SeedResult memory result =
    LIQUIDITY_ADAPTER.seed(
        IArchLaunchLiquidityAdapter.SeedParams({
            token: address(token),
            tokenAmount: lpTokens,
            wethAmount: lpWeth,
            lockOwner: creator,
            unlockTime: unlockTime,
            permanent: false
        })
    );

token.addMarketPair(result.market);
```

`permanent: true` is used for V4 bonding-curve graduation. It sends the V4
position directly to `0x000000000000000000000000000000000000dEaD`.

For an already-wired token, users call the bound provisioner instead of the
adapter. A token with no market supplies `address(0)` as `expectedMarket`; the
provisioner registers only that deferred first canonical market. Existing
markets must already be registered by the token. Every resulting position is
locked to `msg.sender` or permanently burned, and unused token/WETH inputs are
refunded atomically.

## Install and build

```bash
git clone --recurse-submodules https://github.com/ArchLiquid/archliquid-launchpad.git
cd archliquid-launchpad
forge build
forge test
forge build --sizes
```

The exact compiler configuration and remappings to Core, Lockers, and Token are
defined in [`foundry.toml`](foundry.toml).

## Create a V3 fixed-price presale

The stock token must be approved in the launchpad's immutable registry. The
creation transaction sends exactly `launchpad.FEE()`; contributions are sent to
the returned presale afterward.

```solidity
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchLaunchpad} from "@archliquid/launchpad/ArchLaunchpad.sol";
import {ArchPresale} from "@archliquid/launchpad/ArchPresale.sol";

ArchPresale.TokenConfig memory tokenConfig = ArchPresale.TokenConfig({
    name: "Arch Example",
    symbol: "ARCHX",
    totalSupply: 1_000_000 ether,
    taxBps: 300,
    stock: IERC20(approvedStockToken),
    creatorFeeBps: 50
});

ArchPresale.SaleConfig memory saleConfig = ArchPresale.SaleConfig({
    softCap: uint128(50 ether),
    hardCap: uint128(100 ether),
    start: uint64(block.timestamp + 1 days),
    end: uint64(block.timestamp + 8 days),
    perWalletCap: uint128(5 ether),
    salePct: 60,
    lpPct: 30,
    poolFee: 3000,
    lpLockDuration: uint64(365 days),
    teamCliff: uint64(block.timestamp + 38 days),
    teamEnd: uint64(block.timestamp + 188 days)
});

address presale = launchpad.createPresale{
    value: launchpad.FEE()
}(tokenConfig, saleConfig);
```

The constructor enforces:

- `hardCap >= softCap > 0`;
- a future start and an end later than the start;
- `salePct > 0`, `lpPct > 0`, and their sum at most 100%;
- a V3 fee tier of 100, 500, 3000, or 10000;
- a liquidity lock from 30 days through 3650 days;
- a team cliff at or after sale end and a team end at or after the cliff; and
- the same 1%–5% trade-tax, 1% creator-fee, and 6% combined bounds enforced by
  `ArchToken`.

### Presale participant flow

```solidity
ArchPresale sale = ArchPresale(payable(presale));

sale.contribute{value: 1 ether}();

// At END, or immediately at HARD_CAP, any caller can finalize a successful sale.
sale.finalize();
sale.claim();
```

The code derives a fixed token price so a full hard-cap raise sells exactly the
sale allocation. A successful raise sends 3% to the treasury and uses the
remaining ETH to seed V3 liquidity. The position is locked for the configured
duration; the team receives no contributed ETH.

If the soft cap is missed, any caller can mark the sale canceled after the end,
and contributors reclaim their full recorded contribution:

```solidity
sale.cancel();
sale.refund();
```

Team tokens remain in the presale. Nothing is claimable before `teamCliff`; at
the cliff, vesting accumulated linearly from the sale end becomes available,
then continues linearly through `teamEnd`. `claimTeam()` always transfers the
vested amount to the immutable creator.

## Create a V3 bonding curve

```solidity
import {ArchBondingCurve} from
    "@archliquid/launchpad/ArchBondingCurve.sol";

ArchBondingCurve.TokenConfig memory tokenConfig =
    ArchBondingCurve.TokenConfig({
        name: "Arch Curve",
        symbol: "ARCHC",
        totalSupply: 1_000_000 ether,
        taxBps: 300,
        stock: IERC20(approvedStockToken),
        creatorFeeBps: 0
    });

ArchBondingCurve.CurveConfig memory curveConfig =
    ArchBondingCurve.CurveConfig({
        curvePct: 80,
        virtualEth: uint128(10 ether),
        gradEth: uint128(50 ether),
        poolFee: 3000
    });

address curve = launchpad.createCurve{
    value: launchpad.FEE()
}(tokenConfig, curveConfig);
```

`curvePct` must be at least 50 and below 100. Both reserve values must be
positive, and `gradEth` cannot exceed nine times `virtualEth`, which keeps
graduation reachable within the productive curve range.

### Quote and trade

```solidity
ArchBondingCurve market = ArchBondingCurve(payable(curve));

(uint256 quotedTokens, uint256 fee) = market.quoteBuy(1 ether);
market.buy{value: 1 ether}(quotedTokens * 99 / 100);

(uint256 quotedEth,) = market.quoteSell(tokensToSell);
IERC20(address(market.token())).approve(address(market), tokensToSell);
market.sell(tokensToSell, quotedEth * 99 / 100);
```

Curve trades charge a fixed 1% treasury fee. Quote methods are views, while
`buy` and `sell` independently enforce the supplied minimum output. When net
real ETH reaches `GRAD_ETH`, the same buy transaction creates V3 liquidity,
burns the position NFT, finalizes token wiring, and disables further curve
trading.

## V4 deployment wiring

The additive deployment script is
[`DeployV4UserLiquidity.s.sol`](script/DeployV4UserLiquidity.s.sol). It refuses
every chain except Robinhood testnet, validates every upstream dependency, and
deploys a V4 family without mutating the V3 release.

The family is wired in this order:

1. Deploy the canonical locker, liquidity adapter, liquidity provisioner, swap
   adapter, token factory, child deployers, and launchpad.
2. Bind each child deployer to its launchpad exactly once.
3. Bind the liquidity adapter to the provisioner, token factory, and launch
   registry exactly once.
4. Exempt only the adapter from the locker fee required for launch-created
   positions.
5. Verify owner, immutable dependency, factory authorization, canonical AMM,
   and runtime-code invariants before promoting the manifest.

The retired V2 launch family is not supported for new launches. Its immutable
testnet contracts and already-published source remain inspectable through
Sourcify.

## Dependency pins

| Dependency | Commit |
|---|---|
| ArchLiquid Core | `b1f0bec05bdee32cdcb3dfa74310f2f5476760be` |
| ArchLiquid Lockers | `f47efd092c263d1d185a777079413119b546b4ac` |
| ArchLiquid Token | `e2413e9e1fdc86d93cf4544b2e7fa6adcd9976f1` |
| Foundry standard library | `c179529c064588ede54a0661ec3cc98219460d07` |
| OpenZeppelin Contracts | `5fd1781b1454fd1ef8e722282f86f9293cacf256` |

## Tests

The suites cover caps and windows, approved-stock enforcement, contribution and
refund accounting, finalization atomicity, hostile pool initialization, V4 hook
and fee policy, V4 Permit2 custody,
LP and position locking, team vesting, curve solvency, tax-aware swaps,
distribution processing, graduation, permanent liquidity, deferred first-pair
registration, refund rollback, donation resistance, reentrancy, exact approvals,
and post-graduation behavior.

```bash
forge fmt --check
forge test -vv
forge build --sizes

# Read-only verification against the live Robinhood testnet V4 stack
forge test --match-path 'test/*V4*Fork.t.sol' \
  --fork-url https://rpc.testnet.chain.robinhood.com -vv
```

## Related repositories

- [Core](https://github.com/ArchLiquid/archliquid-core)
- [Lockers](https://github.com/ArchLiquid/archliquid-lockers)
- [Token](https://github.com/ArchLiquid/archliquid-token)
- [Integration contracts](https://github.com/ArchLiquid/archliquid-contracts)

## Security

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability. Use GitHub's
private vulnerability reporting flow; do not publish exploit details in an
issue.

## License

Copyright (c) 2026 ArchLiquid. This repository is public source, not open
source. No permission to use, copy, modify, compile, deploy, or distribute the
materials is granted without prior written approval. See [LICENSE](LICENSE).
Files marked `LicenseRef-ArchLiquid-Proprietary` are governed by that license.
