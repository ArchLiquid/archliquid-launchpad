// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {ArchV4LaunchLiquidityAdapter} from "../src/ArchV4LaunchLiquidityAdapter.sol";
import {ArchV4UserLiquidityProvisioner} from "../src/ArchV4UserLiquidityProvisioner.sol";
import {ArchV4SwapRouterAdapter} from "../src/ArchV4SwapRouterAdapter.sol";
import {ArchAdapterTokenFactory} from "../src/ArchAdapterTokenFactory.sol";
import {ArchAdapterLaunchpad} from "../src/ArchAdapterLaunchpad.sol";
import {ArchAdapterPresaleDeployer} from "../src/ArchAdapterPresaleDeployer.sol";
import {ArchAdapterCurveDeployer} from "../src/ArchAdapterCurveDeployer.sol";
import {IArchLaunchRegistry} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {
    IPermit2AllowanceTransfer,
    IUniswapV4PositionManager,
    IUniswapV4StateView
} from "../src/interfaces/IUniswapV4.sol";

/// @notice Additive V4-only release. It reuses the already-canary-tested V4
///         locker and swap adapter, and deploys a fresh immutable launch family
///         whose tokens are bound to the price-protected user provisioner.
contract DeployV4UserLiquidity is Script {
    uint24 private constant V4_FEE = 3000;
    uint256 private constant MIN_GAS_BALANCE = 0.02 ether;

    address private constant DEFAULT_TREASURY = 0x48B49CEf2f6071405D6A62228ADC168a7baB2654;
    address private constant DEFAULT_WETH = 0x61293a735E35d76E8980Bf17715b37A0C4196512;
    address private constant DEFAULT_STOCK_REGISTRY = 0xADB4b0D5908C179C97ce5A5b2879Ba3E8497Bd64;
    address private constant DEFAULT_V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address private constant DEFAULT_V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address private constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant DEFAULT_V4_LOCKER = 0x8A1bC51e25b8799a5da57ff55f0262A405Ed2b98;
    address private constant DEFAULT_V4_SWAP = 0xa4C298f17d051634f59Dd37FEE05D4892a8153Ea;

    struct Release {
        ArchV4LaunchLiquidityAdapter adapter;
        ArchV4UserLiquidityProvisioner provisioner;
        ArchAdapterTokenFactory factory;
        ArchAdapterPresaleDeployer presaleDeployer;
        ArchAdapterCurveDeployer curveDeployer;
        ArchAdapterLaunchpad launchpad;
    }

    function run() external {
        require(block.chainid == 46630, "v4 release: wrong chain");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address governance = vm.addr(privateKey);
        address payable treasury = payable(vm.envOr("TESTNET_AMM_TREASURY", DEFAULT_TREASURY));
        IWETH9 weth = IWETH9(vm.envOr("TESTNET_AMM_WETH", DEFAULT_WETH));
        ArchStockRegistry registry = ArchStockRegistry(vm.envOr("TESTNET_AMM_STOCK_REGISTRY", DEFAULT_STOCK_REGISTRY));
        IUniswapV4PositionManager positionManager =
            IUniswapV4PositionManager(vm.envOr("TESTNET_V4_POSITION_MANAGER", DEFAULT_V4_POSITION_MANAGER));
        IUniswapV4StateView stateView = IUniswapV4StateView(vm.envOr("TESTNET_V4_STATE_VIEW", DEFAULT_V4_STATE_VIEW));
        IPermit2AllowanceTransfer permit2 = IPermit2AllowanceTransfer(vm.envOr("TESTNET_PERMIT2", DEFAULT_PERMIT2));
        ArchV4PositionLocker locker = ArchV4PositionLocker(vm.envOr("TESTNET_V4_LOCKER", DEFAULT_V4_LOCKER));
        ArchV4SwapRouterAdapter swapRouter =
            ArchV4SwapRouterAdapter(vm.envOr("TESTNET_V4_SWAP_ROUTER", DEFAULT_V4_SWAP));
        uint256 factoryFee = vm.envOr("TESTNET_AMM_FACTORY_FEE", uint256(0.00015 ether));
        uint256 listingFee = vm.envOr("TESTNET_AMM_LISTING_FEE", uint256(0.001 ether));

        _validateDependencies(
            governance, treasury, weth, registry, positionManager, stateView, permit2, locker, swapRouter
        );

        vm.startBroadcast(privateKey);
        Release memory release;
        release.adapter = new ArchV4LaunchLiquidityAdapter(
            positionManager, stateView, permit2, IERC20(address(weth)), locker, governance
        );
        release.provisioner = new ArchV4UserLiquidityProvisioner(release.adapter);
        release.factory = new ArchAdapterTokenFactory(
            factoryFee,
            treasury,
            governance,
            release.adapter,
            ISwapRouter(address(swapRouter)),
            weth,
            V4_FEE,
            0,
            registry
        );
        release.presaleDeployer = new ArchAdapterPresaleDeployer();
        release.curveDeployer = new ArchAdapterCurveDeployer();
        release.launchpad = new ArchAdapterLaunchpad(
            listingFee,
            treasury,
            release.adapter,
            ISwapRouter(address(swapRouter)),
            weth,
            V4_FEE,
            0,
            governance,
            registry,
            release.presaleDeployer,
            release.curveDeployer
        );
        release.presaleDeployer.setLaunchpad(address(release.launchpad));
        release.curveDeployer.setLaunchpad(address(release.launchpad));
        release.adapter.bindLiquidityProvisioner(address(release.provisioner));
        release.adapter.bindLaunchers(address(release.factory), IArchLaunchRegistry(address(release.launchpad)));
        locker.setFeeExempt(address(release.adapter), true);
        vm.stopBroadcast();

        _validateRelease(release, locker, swapRouter, registry, weth, treasury, governance, factoryFee, listingFee);
        _logRelease(release, locker, swapRouter);
    }

    function _validateDependencies(
        address governance,
        address treasury,
        IWETH9 weth,
        ArchStockRegistry registry,
        IUniswapV4PositionManager positionManager,
        IUniswapV4StateView stateView,
        IPermit2AllowanceTransfer permit2,
        ArchV4PositionLocker locker,
        ArchV4SwapRouterAdapter swapRouter
    ) private view {
        require(governance != address(0) && governance.balance >= MIN_GAS_BALANCE, "v4 release: signer balance");
        require(treasury != address(0), "v4 release: zero treasury");
        require(address(weth).code.length > 0, "v4 release: weth missing");
        require(address(registry).code.length > 0, "v4 release: registry missing");
        require(address(positionManager).code.length > 0, "v4 release: position manager missing");
        require(address(stateView).code.length > 0, "v4 release: state view missing");
        require(address(permit2).code.length > 0, "v4 release: permit2 missing");
        require(address(locker).code.length > 0 && locker.owner() == governance, "v4 release: locker authority");
        require(address(swapRouter).code.length > 0, "v4 release: swap missing");
        require(address(locker.POSITION_MANAGER()) == address(positionManager), "v4 release: locker manager");
        require(locker.POOL_MANAGER() == positionManager.poolManager(), "v4 release: locker pool");
        require(address(swapRouter.POOL_MANAGER()) == positionManager.poolManager(), "v4 release: swap pool");
        require(address(swapRouter.WETH()) == address(weth), "v4 release: swap weth");
    }

    function _validateRelease(
        Release memory release,
        ArchV4PositionLocker locker,
        ArchV4SwapRouterAdapter swapRouter,
        ArchStockRegistry registry,
        IWETH9 weth,
        address treasury,
        address governance,
        uint256 factoryFee,
        uint256 listingFee
    ) private view {
        require(release.adapter.launchersBound(), "v4 release: adapter open");
        require(release.adapter.owner() == governance, "v4 release: adapter owner");
        require(release.adapter.tokenFactory() == address(release.factory), "v4 release: factory binding");
        require(address(release.adapter.launchpad()) == address(release.launchpad), "v4 release: launchpad binding");
        require(
            release.adapter.liquidityProvisioner() == address(release.provisioner), "v4 release: provisioner binding"
        );
        require(locker.feeExempt(address(release.adapter)), "v4 release: locker fee exemption");
        require(address(release.factory.LIQUIDITY_ADAPTER()) == address(release.adapter), "v4 release: factory adapter");
        require(address(release.factory.SWAP_ROUTER()) == address(swapRouter), "v4 release: factory swap");
        require(address(release.factory.WETH()) == address(weth), "v4 release: factory weth");
        require(address(release.factory.STOCK_REGISTRY()) == address(registry), "v4 release: factory registry");
        require(
            release.factory.TREASURY() == treasury && release.factory.KEEPER() == governance,
            "v4 release: factory roles"
        );
        require(release.factory.FEE() == factoryFee && release.factory.tokenCount() == 0, "v4 release: factory state");
        require(address(release.launchpad.LIQUIDITY_ADAPTER()) == address(release.adapter), "v4 release: pad adapter");
        require(address(release.launchpad.SWAP_ROUTER()) == address(swapRouter), "v4 release: pad swap");
        require(address(release.launchpad.WETH()) == address(weth), "v4 release: pad weth");
        require(address(release.launchpad.STOCK_REGISTRY()) == address(registry), "v4 release: pad registry");
        require(
            release.launchpad.TREASURY() == treasury && release.launchpad.KEEPER() == governance,
            "v4 release: pad roles"
        );
        require(
            release.launchpad.FEE() == listingFee && release.launchpad.presaleCount() == 0
                && release.launchpad.curveCount() == 0,
            "v4 release: pad state"
        );
    }

    function _logRelease(Release memory release, ArchV4PositionLocker locker, ArchV4SwapRouterAdapter swapRouter)
        private
        view
    {
        console2.log("== ArchLiquid V4 user-liquidity release ==");
        console2.log("V4 Locker", address(locker));
        console2.log("V4 Swap Router", address(swapRouter));
        console2.log("V4 Liquidity Adapter", address(release.adapter));
        console2.log("V4 Liquidity Provisioner", address(release.provisioner));
        console2.log("V4 Token Factory", address(release.factory));
        console2.log("V4 Presale Deployer", address(release.presaleDeployer));
        console2.log("V4 Curve Deployer", address(release.curveDeployer));
        console2.log("V4 Launchpad", address(release.launchpad));
    }
}
