# ArchLiquid Launchpad

Fixed-price presales and constant-product bonding curves that graduate into
locked Uniswap V2, V3, or V4 liquidity on Robinhood Chain.

> **Status:** Live on Robinhood Chain testnet. Testnet assets have no monetary
> value. Review the contract, network, and transaction details before signing.

## What is included

| Contract | Purpose |
|---|---|
| [`ArchLaunchpad`](src/ArchLaunchpad.sol) | V3 launch factory for approved stock tokens, fixed listing fees, presales, and curves. |
| [`ArchPresale`](src/ArchPresale.sol) | Escrows fixed-price contributions, handles refunds, seeds V3 liquidity, locks the position, and vests the team allocation. |
| [`ArchBondingCurve`](src/ArchBondingCurve.sol) | Buys and sells against virtual reserves, then graduates the remaining inventory into V3 liquidity. |
| [`ArchAdapterLaunchpad`](src/ArchAdapterLaunchpad.sol) | Versioned V2/V4 launch factory bound to one liquidity adapter and one tax-aware swap route. |
| [`ArchAdapterPresale`](src/ArchAdapterPresale.sol) | AMM-neutral presale that delegates pool creation and custody to its pinned adapter. |
| [`ArchAdapterBondingCurve`](src/ArchAdapterBondingCurve.sol) | AMM-neutral curve that graduates through its pinned adapter. |
| [`ArchV2LaunchLiquidityAdapter`](src/ArchV2LaunchLiquidityAdapter.sol) | Seeds an exact-ratio canonical V2 pair and locks or permanently sends its LP tokens. |
| [`ArchV4LaunchLiquidityAdapter`](src/ArchV4LaunchLiquidityAdapter.sol) | Seeds a hookless, static-fee, full-range V4 position and locks or permanently sends its position NFT. |
| [`ArchUserLiquidityProvisioner`](src/ArchUserLiquidityProvisioner.sol) | Adds post-deployment liquidity through one immutable family adapter without accepting a user-selected market, router, spender, or recipient. |
| [`ArchV2SwapRouterAdapter`](src/ArchV2SwapRouterAdapter.sol) | Presents canonical V2 routing through the launch token's router boundary. |
| [`ArchV4SwapRouterAdapter`](src/ArchV4SwapRouterAdapter.sol) | Routes launch-token swaps through V4 and stock-token distribution through the configured V2 stock route. |
| [`ArchPresaleDeployer`](src/ArchPresaleDeployer.sol) | Restricts presale deployment to its configured launchpad. |
| [`ArchCurveDeployer`](src/ArchCurveDeployer.sol) | Restricts curve deployment to its configured launchpad. |
| [`ArchTokenDeployLib`](src/lib/ArchTokenDeployLib.sol) | Shared creation helper for wiring the fixed-supply token inside a launch. |

## Launch paths

```text
V2, V3, or V4 launchpad
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

Each launch is a separate contract with immutable configuration. The V2 and V4
families share launch accounting through `ArchAdapterPresale` and
`ArchAdapterBondingCurve`, but they cannot choose an AMM at runtime. Each
factory is permanently wired to its own adapter, router, locker, WETH, stock
registry, and child deployers.

## Robinhood Chain testnet release

The original V2/V4 release and the additive V2 user-liquidity release
`robinhood-testnet-user-liquidity-2026-08-14-r1` are active on chain ID `46630`.
The V2 fixture is included because the official Robinhood V2 addresses have no
runtime code on testnet. The V4 family uses the live Robinhood testnet V4 stack.

| Component | V2 | V4 |
|---|---|---|
| Launchpad | `0x3FD6651939A2138A5ecD4E17ba741e3ee0D6dfa6` | `0x94eEec9B20cDE4C58E7F982A863e913977AD73Ed` |
| Token factory | `0xCB5756CAC20427a3d6536A7A55CC72B44dA9C1A7` | `0xFf575Bc8DFE5Dd34c17814f71D091F1692e531AF` |
| Liquidity adapter | `0x050F2cF78d3D33e73777Db3BF0A6B476DB668A66` | `0x014e5142D5A6945930832506A5A99030F2B68A16` |
| User-liquidity provisioner | `0xad16a8806EdF001c053A856bD625cbd720335CeA` | Not promoted |
| Swap adapter | `0xb8525F9F98480d0A0f54A834f0A8d407D8CED3F2` | `0xa4C298f17d051634f59Dd37FEE05D4892a8153Ea` |
| Locker | `0xb92D2c218bBb51C0F21fc12a6141596EafD98Def` | `0x8A1bC51e25b8799a5da57ff55f0262A405Ed2b98` |
| Upstream factory or manager | `0x3d51588C41586Bc391A989156fBE6a7ceEd51446` | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |

The V2 router is `0x42F1CF708A3DB2D4f3fF59FE400a8e4530662880`.
The V4 PoolManager is `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
The signed release manifest and the complete address set live in the
[integration contracts repository](https://github.com/ArchLiquid/archliquid-contracts).

## AMM-specific guarantees

The adapter boundary keeps launch accounting identical while enforcing the
rules of the selected AMM:

- V2 checks the router, factory, WETH, locker factory, exact seed consumption,
  and canonical pair identity. Recoverable LP tokens go directly into the
  locker; permanent liquidity is minted directly to the dead address.
- V3 uses the original launch contracts and validates the deterministic pool's
  initial price before minting its full-range NFT.
- V4 allows only hookless pools with a fixed 0.30% fee and tick spacing 60. It
  verifies the exact intended starting price through `StateView`, mints a
  full-range position through `PositionManager`, and leaves no adapter residue.
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

`permanent: true` is used for bonding-curve graduation. It sends the V2 LP
tokens or V4 position directly to `0x000000000000000000000000000000000000dEaD`.

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

## V2 and V4 deployment wiring

The additive deployment script is [`DeployAmmModules.s.sol`](script/DeployAmmModules.s.sol).
It refuses every chain except Robinhood testnet and validates every upstream
dependency before broadcasting. It then deploys one complete V2 family and one
complete V4 family without mutating the V3 release.

Each family is wired in this order:

1. Deploy the canonical locker, liquidity adapter, liquidity provisioner, swap
   adapter, token factory, child deployers, and launchpad.
2. Bind each child deployer to its launchpad exactly once.
3. Bind the liquidity adapter to the provisioner, token factory, and launch
   registry exactly once.
4. Exempt only the adapter from the locker fee required for launch-created
   positions.
5. Verify owner, immutable dependency, factory authorization, canonical AMM,
   and runtime-code invariants before promoting the manifest.

The V2 fixture consumes version-pinned upstream artifacts. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for versions, checksums, and
licenses.

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
refund accounting, finalization atomicity, hostile pool initialization, exact
V2 seeding, canonical-pair checks, V4 hook and fee policy, V4 Permit2 custody,
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
