// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {IUniswapV2Factory as LockerV2Factory} from "@archliquid/lockers/interfaces/IUniswapV2.sol";
import {IUniswapV4PositionManager as LockerV4PositionManager} from "@archliquid/lockers/interfaces/IUniswapV4.sol";
import {ArchV2LaunchLiquidityAdapter} from "../src/ArchV2LaunchLiquidityAdapter.sol";
import {ArchV4LaunchLiquidityAdapter} from "../src/ArchV4LaunchLiquidityAdapter.sol";
import {ArchV2SwapRouterAdapter} from "../src/ArchV2SwapRouterAdapter.sol";
import {ArchV4SwapRouterAdapter} from "../src/ArchV4SwapRouterAdapter.sol";
import {ArchAdapterTokenFactory} from "../src/ArchAdapterTokenFactory.sol";
import {ArchAdapterLaunchpad} from "../src/ArchAdapterLaunchpad.sol";
import {ArchAdapterPresaleDeployer} from "../src/ArchAdapterPresaleDeployer.sol";
import {ArchAdapterCurveDeployer} from "../src/ArchAdapterCurveDeployer.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {IArchLaunchRegistry} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {
    IPermit2AllowanceTransfer,
    IUniswapV4PoolManager,
    IUniswapV4PositionManager,
    IUniswapV4StateView
} from "../src/interfaces/IUniswapV4.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {UniswapV2Artifacts} from "./lib/UniswapV2Artifacts.sol";

interface IMintableAsset is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @notice Additive Robinhood testnet deployment for a functional upstream V2
///         fixture and versioned V2/V4 factories and launchpads. It never
///         mutates or replaces the existing V3 release.
contract DeployAmmModules is Script {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint24 private constant V4_FEE = 3000;

    IUniswapV4PoolManager private constant V4_POOL_MANAGER =
        IUniswapV4PoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IUniswapV4PositionManager private constant V4_POSITION_MANAGER =
        IUniswapV4PositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IUniswapV4StateView private constant V4_STATE_VIEW =
        IUniswapV4StateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    IPermit2AllowanceTransfer private constant PERMIT2 =
        IPermit2AllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // Current r3 mock-asset release. Every value is overridable so a later
    // testnet revision can reuse this additive deployer without source edits.
    address private constant DEFAULT_TREASURY = 0x48B49CEf2f6071405D6A62228ADC168a7baB2654;
    address private constant DEFAULT_WETH = 0x61293a735E35d76E8980Bf17715b37A0C4196512;
    address private constant DEFAULT_STOCK = 0x1c80aC86447c8EEa5D0D70DCa78c632b7A249bEE;
    address private constant DEFAULT_STOCK_REGISTRY = 0xADB4b0D5908C179C97ce5A5b2879Ba3E8497Bd64;

    struct FamilyDeployment {
        address locker;
        address liquidityAdapter;
        address swapRouter;
        address tokenFactory;
        address presaleDeployer;
        address curveDeployer;
        address launchpad;
    }

    function run() external {
        require(block.chainid == 46630, "AMM deploy: wrong chain");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address governance = vm.addr(privateKey);
        address treasury = vm.envOr("TESTNET_AMM_TREASURY", DEFAULT_TREASURY);
        address wethAddress = vm.envOr("TESTNET_AMM_WETH", DEFAULT_WETH);
        address stockAddress = vm.envOr("TESTNET_AMM_STOCK", DEFAULT_STOCK);
        address registryAddress = vm.envOr("TESTNET_AMM_STOCK_REGISTRY", DEFAULT_STOCK_REGISTRY);
        uint256 lockerFee = vm.envOr("TESTNET_AMM_LOCKER_FEE", uint256(0.0002 ether));
        uint256 factoryFee = vm.envOr("TESTNET_AMM_FACTORY_FEE", uint256(0.00015 ether));
        uint256 listingFee = vm.envOr("TESTNET_AMM_LISTING_FEE", uint256(0.001 ether));
        uint256 stockSeedAmount = vm.envOr("TESTNET_AMM_STOCK_SEED", uint256(1_000_000e18));
        uint256 wethSeedAmount = vm.envOr("TESTNET_AMM_WETH_SEED", uint256(0.01 ether));

        _validateExistingInfrastructure(treasury, wethAddress, stockAddress, registryAddress);

        vm.startBroadcast(privateKey);

        IUniswapV2Factory v2Factory = IUniswapV2Factory(UniswapV2Artifacts.deployFactory(governance));
        IUniswapV2Router02 v2Router =
            IUniswapV2Router02(UniswapV2Artifacts.deployRouter(address(v2Factory), wethAddress));
        ArchV2SwapRouterAdapter v2Swap = new ArchV2SwapRouterAdapter(v2Factory);

        // A real direct stock/WETH pair makes tax distribution executable for
        // both added AMM families. The existing testnet assets are mocks.
        IMintableAsset(stockAddress).mint(governance, stockSeedAmount);
        IWETH9(wethAddress).deposit{value: wethSeedAmount}();
        IERC20(stockAddress).approve(address(v2Router), stockSeedAmount);
        IERC20(wethAddress).approve(address(v2Router), wethSeedAmount);
        v2Router.addLiquidity(
            stockAddress,
            wethAddress,
            stockSeedAmount,
            wethSeedAmount,
            stockSeedAmount,
            wethSeedAmount,
            DEAD,
            type(uint256).max
        );
        IERC20(stockAddress).approve(address(v2Router), 0);
        IERC20(wethAddress).approve(address(v2Router), 0);

        FamilyDeployment memory v2 = _deployV2Family(
            governance,
            payable(treasury),
            IWETH9(wethAddress),
            ArchStockRegistry(registryAddress),
            v2Factory,
            v2Router,
            v2Swap,
            lockerFee,
            factoryFee,
            listingFee
        );
        FamilyDeployment memory v4 = _deployV4Family(
            governance,
            payable(treasury),
            IWETH9(wethAddress),
            IERC20(stockAddress),
            ArchStockRegistry(registryAddress),
            v2Swap,
            lockerFee,
            factoryFee,
            listingFee
        );

        vm.stopBroadcast();

        console2.log("== ArchLiquid testnet AMM release ==");
        console2.log("V2 Factory", address(v2Factory));
        console2.log("V2 Router", address(v2Router));
        console2.log("V2 Stock/WETH Pair", v2Factory.getPair(stockAddress, wethAddress));
        _logFamily("V2", v2);
        _logFamily("V4", v4);
        console2.log("V4 PoolManager", address(V4_POOL_MANAGER));
        console2.log("V4 PositionManager", address(V4_POSITION_MANAGER));
        console2.log("V4 StateView", address(V4_STATE_VIEW));
        console2.log("Permit2", address(PERMIT2));
    }

    function _deployV2Family(
        address governance,
        address payable treasury,
        IWETH9 weth,
        ArchStockRegistry registry,
        IUniswapV2Factory v2Factory,
        IUniswapV2Router02 v2Router,
        ArchV2SwapRouterAdapter swapRouter,
        uint256 lockerFee,
        uint256 factoryFee,
        uint256 listingFee
    ) private returns (FamilyDeployment memory deployed) {
        ArchLiquidityLocker locker = new ArchLiquidityLocker(
            lockerFee, treasury, LockerV2Factory(address(v2Factory)), governance
        );
        ArchV2LaunchLiquidityAdapter adapter = new ArchV2LaunchLiquidityAdapter(v2Router, locker, governance);
        ArchAdapterTokenFactory factory = new ArchAdapterTokenFactory(
            factoryFee, treasury, governance, adapter, ISwapRouter(address(swapRouter)), weth, 0, 0, registry
        );
        ArchAdapterPresaleDeployer presaleDeployer = new ArchAdapterPresaleDeployer();
        ArchAdapterCurveDeployer curveDeployer = new ArchAdapterCurveDeployer();
        ArchAdapterLaunchpad launchpad = new ArchAdapterLaunchpad(
            listingFee,
            treasury,
            adapter,
            ISwapRouter(address(swapRouter)),
            weth,
            0,
            0,
            governance,
            registry,
            presaleDeployer,
            curveDeployer
        );
        presaleDeployer.setLaunchpad(address(launchpad));
        curveDeployer.setLaunchpad(address(launchpad));
        adapter.bindLaunchers(address(factory), IArchLaunchRegistry(address(launchpad)));
        locker.setFeeExempt(address(adapter), true);

        deployed = FamilyDeployment({
            locker: address(locker),
            liquidityAdapter: address(adapter),
            swapRouter: address(swapRouter),
            tokenFactory: address(factory),
            presaleDeployer: address(presaleDeployer),
            curveDeployer: address(curveDeployer),
            launchpad: address(launchpad)
        });
    }

    function _deployV4Family(
        address governance,
        address payable treasury,
        IWETH9 weth,
        IERC20 stock,
        ArchStockRegistry registry,
        ArchV2SwapRouterAdapter stockRouter,
        uint256 lockerFee,
        uint256 factoryFee,
        uint256 listingFee
    ) private returns (FamilyDeployment memory deployed) {
        ArchV4PositionLocker locker = new ArchV4PositionLocker(
            lockerFee, treasury, LockerV4PositionManager(address(V4_POSITION_MANAGER)), governance
        );
        ArchV4LaunchLiquidityAdapter adapter = new ArchV4LaunchLiquidityAdapter(
            V4_POSITION_MANAGER, V4_STATE_VIEW, PERMIT2, IERC20(address(weth)), locker, governance
        );
        ArchV4SwapRouterAdapter swapRouter = new ArchV4SwapRouterAdapter(
            V4_POOL_MANAGER, IERC20(address(weth)), stock, ISwapRouter(address(stockRouter))
        );
        ArchAdapterTokenFactory factory = new ArchAdapterTokenFactory(
            factoryFee, treasury, governance, adapter, ISwapRouter(address(swapRouter)), weth, V4_FEE, 0, registry
        );
        ArchAdapterPresaleDeployer presaleDeployer = new ArchAdapterPresaleDeployer();
        ArchAdapterCurveDeployer curveDeployer = new ArchAdapterCurveDeployer();
        ArchAdapterLaunchpad launchpad = new ArchAdapterLaunchpad(
            listingFee,
            treasury,
            adapter,
            ISwapRouter(address(swapRouter)),
            weth,
            V4_FEE,
            0,
            governance,
            registry,
            presaleDeployer,
            curveDeployer
        );
        presaleDeployer.setLaunchpad(address(launchpad));
        curveDeployer.setLaunchpad(address(launchpad));
        adapter.bindLaunchers(address(factory), IArchLaunchRegistry(address(launchpad)));
        locker.setFeeExempt(address(adapter), true);

        deployed = FamilyDeployment({
            locker: address(locker),
            liquidityAdapter: address(adapter),
            swapRouter: address(swapRouter),
            tokenFactory: address(factory),
            presaleDeployer: address(presaleDeployer),
            curveDeployer: address(curveDeployer),
            launchpad: address(launchpad)
        });
    }

    function _validateExistingInfrastructure(address treasury, address weth, address stock, address registry)
        private
        view
    {
        require(treasury.code.length > 0, "AMM deploy: invalid treasury");
        require(weth.code.length > 0, "AMM deploy: invalid weth");
        require(stock.code.length > 0, "AMM deploy: invalid stock");
        require(registry.code.length > 0, "AMM deploy: invalid registry");
        require(ArchStockRegistry(registry).isApproved(stock), "AMM deploy: stock not approved");
        require(ArchStockRegistry(registry).stockSwapExecutor().code.length > 0, "AMM deploy: no executor");
        require(address(V4_POSITION_MANAGER).code.length > 0, "AMM deploy: invalid v4 manager");
        require(V4_POSITION_MANAGER.poolManager() == address(V4_POOL_MANAGER), "AMM deploy: v4 mismatch");
        require(address(V4_STATE_VIEW).code.length > 0, "AMM deploy: invalid state view");
        require(address(PERMIT2).code.length > 0, "AMM deploy: invalid permit2");
    }

    function _logFamily(string memory name, FamilyDeployment memory deployed) private pure {
        console2.log(string.concat(name, " Locker"), deployed.locker);
        console2.log(string.concat(name, " LiquidityAdapter"), deployed.liquidityAdapter);
        console2.log(string.concat(name, " SwapRouter"), deployed.swapRouter);
        console2.log(string.concat(name, " TokenFactory"), deployed.tokenFactory);
        console2.log(string.concat(name, " PresaleDeployer"), deployed.presaleDeployer);
        console2.log(string.concat(name, " CurveDeployer"), deployed.curveDeployer);
        console2.log(string.concat(name, " Launchpad"), deployed.launchpad);
    }
}
