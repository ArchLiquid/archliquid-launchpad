# ArchLiquid Launchpad

Fixed-price presales and constant-product bonding-curve launches for ArchLiquid
distribution tokens.

> **Status:** Testnet preview. These contracts have not been audited by an
> external security firm. Review the source and run the test suite before
> interacting with a deployment.

## What is included

| Contract | Purpose |
|---|---|
| [`ArchLaunchpad`](src/ArchLaunchpad.sol) | Validates approved stock tokens, charges the immutable listing fee, and creates launches. |
| [`ArchPresale`](src/ArchPresale.sol) | Escrows fixed-price contributions, handles refunds, seeds V3 liquidity, locks the position, and vests the team allocation. |
| [`ArchBondingCurve`](src/ArchBondingCurve.sol) | Buys and sells against virtual reserves, then graduates collected ETH and remaining tokens into V3 liquidity. |
| [`ArchPresaleDeployer`](src/ArchPresaleDeployer.sol) | Restricts presale deployment to its configured launchpad. |
| [`ArchCurveDeployer`](src/ArchCurveDeployer.sol) | Restricts curve deployment to its configured launchpad. |
| [`ArchTokenDeployLib`](src/lib/ArchTokenDeployLib.sol) | Shared creation helper for wiring the fixed-supply token inside a launch. |

## Launch paths

```text
ArchLaunchpad
  │
  ├── fixed-price presale
  │     contributions ──> soft/hard cap decision
  │                           ├── missed ──> full contributor refunds
  │                           └── reached ──> V3 liquidity locked
  │                                          + contributor claims
  │                                          + team token vesting
  │
  └── bonding curve
        buys/sells against virtual reserves
                    │ reaches graduation threshold
                    v
             remaining tokens + ETH ──> V3 liquidity NFT burned
```

`ArchLaunchpad` holds no contribution or curve-trading funds. Each launch is a
separate contract with immutable configuration.

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

## Create a fixed-price presale

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

## Create a bonding curve

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

## Deployment wiring

The launchpad constructor receives immutable treasury, V3, WETH, keeper,
registry, locker, and deployer addresses. Before launches are accepted:

1. Set the launchpad address once on `ArchPresaleDeployer` and
   `ArchCurveDeployer`.
2. Authorize the launchpad as a factory on `ArchV3PositionLocker` so it can
   waive the lock fee for a newly created presale.
3. Approve supported stock tokens and set a stock swap executor in
   `ArchStockRegistry`.
4. Transfer or accept administrative ownership at the intended controllers.

## Dependency pins

| Dependency | Commit |
|---|---|
| ArchLiquid Core | `b1f0bec05bdee32cdcb3dfa74310f2f5476760be` |
| ArchLiquid Lockers | `a91771ca0ff37598fe79e4a01d214459bfeddb20` |
| ArchLiquid Token | `b5cd8124c39a2e46bee19f74ea8f735178a0276b` |
| Foundry standard library | `c179529c064588ede54a0661ec3cc98219460d07` |
| OpenZeppelin Contracts | `5fd1781b1454fd1ef8e722282f86f9293cacf256` |

## Tests

The suites cover caps and windows, approved-stock enforcement, contribution
and refund accounting, finalization atomicity, V3 pool-price griefing, LP locks,
team vesting, underfilled sales, curve quotes and slippage, buy/sell solvency,
graduation, LP burning, and post-graduation behavior.

```bash
forge fmt --check
forge test -vv
forge build --sizes
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
