// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ArchPresale} from "./ArchPresale.sol";
import {ArchBondingCurve} from "./ArchBondingCurve.sol";
import {ArchPresaleDeployer} from "./ArchPresaleDeployer.sol";
import {ArchCurveDeployer} from "./ArchCurveDeployer.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

/// @title ArchLaunchpad
/// @notice Creates fixed-price presales of RWA distributor tokens. Charges the
///         flat listing fee, enforces the approved-stock allowlist, and grants
///         each new presale a lock-fee exemption so it can lock liquidity at
///         finalize without spare ETH. Holds no user funds itself.
contract ArchLaunchpad is ReentrancyGuard {
    /// @notice Flat listing fee, immutable.
    uint256 public immutable FEE;
    address payable public immutable TREASURY;
    ArchV3PositionLocker public immutable LOCKER;
    INonfungiblePositionManager public immutable NFPM;
    ISwapRouter public immutable SWAP_ROUTER;
    IWETH9 public immutable WETH;
    uint24 public immutable STOCK_POOL_FEE;
    address public immutable KEEPER;
    ArchStockRegistry public immutable STOCK_REGISTRY;
    ArchPresaleDeployer public immutable PRESALE_DEPLOYER;
    ArchCurveDeployer public immutable CURVE_DEPLOYER;

    address[] public presales;
    address[] public curves;

    event PresaleCreated(address indexed presale, address indexed creator, string symbol);
    event CurveCreated(address indexed curve, address indexed creator, string symbol);

    constructor(
        uint256 fee,
        address payable treasury,
        ArchV3PositionLocker locker,
        INonfungiblePositionManager nfpm,
        ISwapRouter swapRouter,
        IWETH9 weth,
        uint24 stockPoolFee,
        address keeper,
        ArchStockRegistry stockRegistry,
        ArchPresaleDeployer presaleDeployer,
        ArchCurveDeployer curveDeployer
    ) {
        require(treasury != address(0), "launchpad: zero treasury");
        require(keeper != address(0), "launchpad: zero keeper");
        require(address(stockRegistry) != address(0), "launchpad: zero registry");
        require(
            address(presaleDeployer) != address(0) && address(curveDeployer) != address(0), "launchpad: zero deployer"
        );
        FEE = fee;
        TREASURY = treasury;
        LOCKER = locker;
        NFPM = nfpm;
        SWAP_ROUTER = swapRouter;
        WETH = weth;
        STOCK_POOL_FEE = stockPoolFee;
        KEEPER = keeper;
        STOCK_REGISTRY = stockRegistry;
        PRESALE_DEPLOYER = presaleDeployer;
        CURVE_DEPLOYER = curveDeployer;
    }

    function presaleCount() external view returns (uint256) {
        return presales.length;
    }

    function curveCount() external view returns (uint256) {
        return curves.length;
    }

    /// @notice Deploy a presale. `msg.value` must equal the flat listing fee;
    ///         contributions are collected by the presale itself, not here.
    function createPresale(ArchPresale.TokenConfig calldata t, ArchPresale.SaleConfig calldata s)
        external
        payable
        nonReentrant
        returns (address presaleAddr)
    {
        require(msg.value == FEE, "launchpad: wrong fee");
        STOCK_REGISTRY.requireApproved(address(t.stock));

        ArchPresale.Infra memory infra = ArchPresale.Infra({
            treasury: TREASURY,
            locker: LOCKER,
            nfpm: NFPM,
            swapRouter: SWAP_ROUTER,
            weth: WETH,
            stockPoolFee: STOCK_POOL_FEE,
            stockSwapExecutor: IArchStockSwapExecutor(STOCK_REGISTRY.stockSwapExecutor()),
            keeper: KEEPER
        });

        presaleAddr = PRESALE_DEPLOYER.deploy(msg.sender, infra, t, s);

        // let the presale lock its LP without paying the flat lock fee (the
        // listing + raise fees already cover the flow)
        LOCKER.setFeeExempt(presaleAddr, true);

        presales.push(presaleAddr);

        (bool ok,) = TREASURY.call{value: msg.value}("");
        require(ok, "launchpad: fee send failed");

        emit PresaleCreated(presaleAddr, msg.sender, t.symbol);
    }

    /// @notice Deploy a bonding-curve fair launch. `msg.value` must equal the
    ///         flat listing fee; trading fees are collected by the curve.
    function createCurve(ArchBondingCurve.TokenConfig calldata t, ArchBondingCurve.CurveConfig calldata c)
        external
        payable
        nonReentrant
        returns (address curveAddr)
    {
        require(msg.value == FEE, "launchpad: wrong fee");
        STOCK_REGISTRY.requireApproved(address(t.stock));

        ArchBondingCurve.Infra memory infra = ArchBondingCurve.Infra({
            treasury: TREASURY,
            nfpm: NFPM,
            swapRouter: SWAP_ROUTER,
            weth: WETH,
            stockPoolFee: STOCK_POOL_FEE,
            stockSwapExecutor: IArchStockSwapExecutor(STOCK_REGISTRY.stockSwapExecutor()),
            keeper: KEEPER
        });

        curveAddr = CURVE_DEPLOYER.deploy(msg.sender, infra, t, c);
        curves.push(curveAddr);

        (bool ok,) = TREASURY.call{value: msg.value}("");
        require(ok, "launchpad: fee send failed");

        emit CurveCreated(curveAddr, msg.sender, t.symbol);
    }
}
