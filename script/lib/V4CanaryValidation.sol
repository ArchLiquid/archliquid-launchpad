// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {ArchAdapterTokenFactory} from "../../src/ArchAdapterTokenFactory.sol";
import {ArchV4LaunchLiquidityAdapter} from "../../src/ArchV4LaunchLiquidityAdapter.sol";
import {ArchV4UserLiquidityProvisioner} from "../../src/ArchV4UserLiquidityProvisioner.sol";
import {ArchV4SwapRouterAdapter} from "../../src/ArchV4SwapRouterAdapter.sol";
import {IUniswapV4PositionManager, IUniswapV4StateView} from "../../src/interfaces/IUniswapV4.sol";

/// @dev V4 dependency getters stay local to release validation so the
///      production interfaces and existing integrations stay unchanged.
interface IV4CanaryStateViewDependencies {
    function poolManager() external view returns (address);
}

interface IV4CanaryPositionManagerDependencies {
    function permit2() external view returns (address);
}

/// @notice Checks a coherent, fresh V4 testnet release without changing state.
/// @dev Getter consistency verifies wiring; it does not authenticate source
///      code. Operators must independently review the selected release address.
library V4CanaryValidation {
    uint256 internal constant CHAIN_ID = 46630;
    uint256 internal constant SEED_ETH = 0.001 ether;
    uint256 internal constant MAX_FACTORY_FEE = 0.001 ether;

    struct Release {
        ArchV4LaunchLiquidityAdapter adapter;
        ArchV4UserLiquidityProvisioner provisioner;
        IERC20 weth;
        ArchV4PositionLocker locker;
        IUniswapV4PositionManager positionManager;
        IUniswapV4StateView stateView;
        uint256 factoryFee;
        uint256 value;
    }

    function validate(ArchAdapterTokenFactory factory, IERC20 stock, uint256 maximumFactoryFee)
        internal
        view
        returns (Release memory release)
    {
        require(block.chainid == CHAIN_ID, "v4 canary: wrong chain");
        require(maximumFactoryFee <= MAX_FACTORY_FEE, "v4 canary: excessive fee ceiling");
        require(address(factory).code.length > 0, "v4 canary: factory missing");
        require(address(stock).code.length > 0, "v4 canary: stock missing");
        require(factory.tokenCount() == 0, "v4 canary: release not fresh");
        release.factoryFee = factory.FEE();
        require(release.factoryFee <= maximumFactoryFee, "v4 canary: factory fee exceeds ceiling");
        release.value = release.factoryFee + 2 * SEED_ETH;

        release.adapter = ArchV4LaunchLiquidityAdapter(address(factory.LIQUIDITY_ADAPTER()));
        require(address(release.adapter).code.length > 0, "v4 canary: adapter missing");
        require(release.adapter.launchersBound(), "v4 canary: adapter not bound");
        require(release.adapter.tokenFactory() == address(factory), "v4 canary: factory binding");
        release.provisioner = ArchV4UserLiquidityProvisioner(payable(release.adapter.liquidityProvisioner()));
        require(address(release.provisioner).code.length > 0, "v4 canary: provisioner missing");
        require(address(release.provisioner.ADAPTER()) == address(release.adapter), "v4 canary: provisioner binding");

        release.weth = IERC20(address(factory.WETH()));
        require(address(release.weth).code.length > 0, "v4 canary: weth missing");
        require(address(stock) != address(release.weth), "v4 canary: stock is weth");
        require(release.adapter.weth() == address(release.weth), "v4 canary: adapter weth");
        require(address(release.provisioner.WETH()) == address(release.weth), "v4 canary: provisioner weth");

        address poolManager = address(release.adapter.POOL_MANAGER());
        release.positionManager = release.adapter.POSITION_MANAGER();
        release.stateView = release.adapter.STATE_VIEW();
        address permit2 = address(release.adapter.PERMIT2());
        release.locker = release.adapter.LOCKER();
        require(poolManager.code.length > 0, "v4 canary: pool manager missing");
        require(address(release.positionManager).code.length > 0, "v4 canary: position manager missing");
        require(address(release.stateView).code.length > 0, "v4 canary: state view missing");
        require(permit2.code.length > 0, "v4 canary: permit2 missing");
        require(address(release.locker).code.length > 0, "v4 canary: locker missing");
        require(release.positionManager.poolManager() == poolManager, "v4 canary: position manager pool");
        require(
            IV4CanaryStateViewDependencies(address(release.stateView)).poolManager() == poolManager,
            "v4 canary: state view pool"
        );
        require(
            IV4CanaryPositionManagerDependencies(address(release.positionManager)).permit2() == permit2,
            "v4 canary: position manager permit2"
        );
        require(
            address(release.locker.POSITION_MANAGER()) == address(release.positionManager), "v4 canary: locker manager"
        );
        require(release.locker.POOL_MANAGER() == poolManager, "v4 canary: locker pool");
        require(release.locker.feeExempt(address(release.adapter)), "v4 canary: locker fee exemption");

        ArchV4SwapRouterAdapter swapRouter = ArchV4SwapRouterAdapter(address(factory.SWAP_ROUTER()));
        require(address(swapRouter).code.length > 0, "v4 canary: swap router missing");
        require(address(swapRouter.POOL_MANAGER()) == poolManager, "v4 canary: swap pool");
        require(address(swapRouter.WETH()) == address(release.weth), "v4 canary: swap weth");
        require(factory.TOKEN_POOL_FEE() == 3000 && factory.STOCK_POOL_FEE() == 0, "v4 canary: factory fee policy");

        ArchStockRegistry registry = factory.STOCK_REGISTRY();
        require(address(registry).code.length > 0, "v4 canary: registry missing");
        require(registry.isApproved(address(stock)), "v4 canary: stock not approved");
        require(registry.stockSwapExecutor().code.length > 0, "v4 canary: executor missing");
    }
}
