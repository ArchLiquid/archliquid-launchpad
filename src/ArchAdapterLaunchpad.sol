// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ArchAdapterPresale} from "./ArchAdapterPresale.sol";
import {ArchAdapterBondingCurve} from "./ArchAdapterBondingCurve.sol";
import {ArchAdapterPresaleDeployer} from "./ArchAdapterPresaleDeployer.sol";
import {ArchAdapterCurveDeployer} from "./ArchAdapterCurveDeployer.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {IArchLaunchLiquidityAdapter, IArchLaunchRegistry} from "./interfaces/IArchLaunchLiquidityAdapter.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

/// @title ArchAdapterLaunchpad
/// @notice Versioned launchpad pinned to one AMM-family liquidity adapter and
///         one tax-aware swap route. It is a registry for adapter authorization;
///         only children created through this contract can seed launch pools.
contract ArchAdapterLaunchpad is ReentrancyGuard, IArchLaunchRegistry {
    uint256 public immutable FEE;
    address payable public immutable TREASURY;
    IArchLaunchLiquidityAdapter public immutable LIQUIDITY_ADAPTER;
    ISwapRouter public immutable SWAP_ROUTER;
    IWETH9 public immutable WETH;
    uint24 public immutable TOKEN_POOL_FEE;
    uint24 public immutable STOCK_POOL_FEE;
    address public immutable KEEPER;
    ArchStockRegistry public immutable STOCK_REGISTRY;
    ArchAdapterPresaleDeployer public immutable PRESALE_DEPLOYER;
    ArchAdapterCurveDeployer public immutable CURVE_DEPLOYER;

    mapping(address => bool) public isLaunch;
    address[] public presales;
    address[] public curves;

    event PresaleCreated(address indexed presale, address indexed creator, string symbol);
    event CurveCreated(address indexed curve, address indexed creator, string symbol);

    constructor(
        uint256 fee,
        address payable treasury,
        IArchLaunchLiquidityAdapter liquidityAdapter,
        ISwapRouter swapRouter,
        IWETH9 weth,
        uint24 tokenPoolFee,
        uint24 stockPoolFee,
        address keeper,
        ArchStockRegistry stockRegistry,
        ArchAdapterPresaleDeployer presaleDeployer,
        ArchAdapterCurveDeployer curveDeployer
    ) {
        require(treasury != address(0), "adapter launchpad: zero treasury");
        require(address(liquidityAdapter).code.length > 0, "adapter launchpad: invalid adapter");
        require(address(swapRouter).code.length > 0, "adapter launchpad: invalid router");
        require(address(weth).code.length > 0, "adapter launchpad: invalid weth");
        require(liquidityAdapter.weth() == address(weth), "adapter launchpad: weth mismatch");
        require(keeper != address(0), "adapter launchpad: zero keeper");
        require(address(stockRegistry).code.length > 0, "adapter launchpad: invalid registry");
        require(
            address(presaleDeployer).code.length > 0 && address(curveDeployer).code.length > 0,
            "adapter launchpad: invalid deployer"
        );

        FEE = fee;
        TREASURY = treasury;
        LIQUIDITY_ADAPTER = liquidityAdapter;
        SWAP_ROUTER = swapRouter;
        WETH = weth;
        TOKEN_POOL_FEE = tokenPoolFee;
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

    function createPresale(
        ArchAdapterPresale.TokenConfig calldata tokenConfig,
        ArchAdapterPresale.SaleConfig calldata saleConfig
    ) external payable nonReentrant returns (address presale) {
        require(msg.value == FEE, "adapter launchpad: wrong fee");
        STOCK_REGISTRY.requireApproved(address(tokenConfig.stock));

        ArchAdapterPresale.Infra memory infra = ArchAdapterPresale.Infra({
            treasury: TREASURY,
            liquidityAdapter: LIQUIDITY_ADAPTER,
            swapRouter: SWAP_ROUTER,
            weth: WETH,
            tokenPoolFee: TOKEN_POOL_FEE,
            stockPoolFee: STOCK_POOL_FEE,
            stockSwapExecutor: IArchStockSwapExecutor(STOCK_REGISTRY.stockSwapExecutor()),
            keeper: KEEPER
        });

        presale = PRESALE_DEPLOYER.deploy(msg.sender, infra, tokenConfig, saleConfig);
        isLaunch[presale] = true;
        presales.push(presale);
        _payListingFee();
        emit PresaleCreated(presale, msg.sender, tokenConfig.symbol);
    }

    function createCurve(
        ArchAdapterBondingCurve.TokenConfig calldata tokenConfig,
        ArchAdapterBondingCurve.CurveConfig calldata curveConfig
    ) external payable nonReentrant returns (address curve) {
        require(msg.value == FEE, "adapter launchpad: wrong fee");
        STOCK_REGISTRY.requireApproved(address(tokenConfig.stock));

        ArchAdapterBondingCurve.Infra memory infra = ArchAdapterBondingCurve.Infra({
            treasury: TREASURY,
            liquidityAdapter: LIQUIDITY_ADAPTER,
            swapRouter: SWAP_ROUTER,
            weth: WETH,
            tokenPoolFee: TOKEN_POOL_FEE,
            stockPoolFee: STOCK_POOL_FEE,
            stockSwapExecutor: IArchStockSwapExecutor(STOCK_REGISTRY.stockSwapExecutor()),
            keeper: KEEPER
        });

        curve = CURVE_DEPLOYER.deploy(msg.sender, infra, tokenConfig, curveConfig);
        isLaunch[curve] = true;
        curves.push(curve);
        _payListingFee();
        emit CurveCreated(curve, msg.sender, tokenConfig.symbol);
    }

    function _payListingFee() private {
        (bool paid,) = TREASURY.call{value: msg.value}("");
        require(paid, "adapter launchpad: fee send failed");
    }
}
