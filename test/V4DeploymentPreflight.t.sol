// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {DeployV4UserLiquidity} from "../script/DeployV4UserLiquidity.s.sol";
import {ArchAdapterTokenFactory} from "../src/ArchAdapterTokenFactory.sol";
import {ArchV4SwapRouterAdapter} from "../src/ArchV4SwapRouterAdapter.sol";
import {IArchLaunchLiquidityAdapter} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {
    IPermit2AllowanceTransfer,
    IUniswapV4PositionManager,
    IUniswapV4StateView
} from "../src/interfaces/IUniswapV4.sol";
import {MockERC20, MockWETH} from "./mocks/Mocks.sol";

// Only dependency identity is modeled: these fixtures never swap, mint or
// broadcast. A custom executor deliberately has no canonical-only getters.
contract PreflightContract {}

contract PreflightPositionManager {
    address public poolManager;
    address public permit2;

    constructor(address manager, address permit) {
        poolManager = manager;
        permit2 = permit;
    }

    function setPoolManager(address manager) external {
        poolManager = manager;
    }

    function setPermit2(address permit) external {
        permit2 = permit;
    }
}

contract PreflightStateView {
    address public poolManager;

    constructor(address manager) {
        poolManager = manager;
    }

    function setPoolManager(address manager) external {
        poolManager = manager;
    }
}

contract PreflightLocker {
    address public owner;
    address public POSITION_MANAGER;
    address public POOL_MANAGER;

    constructor(address governance, address positionManager, address poolManager) {
        owner = governance;
        POSITION_MANAGER = positionManager;
        POOL_MANAGER = poolManager;
    }

    function setOwner(address governance) external {
        owner = governance;
    }

    function setPositionManager(address positionManager) external {
        POSITION_MANAGER = positionManager;
    }

    function setPoolManager(address manager) external {
        POOL_MANAGER = manager;
    }
}

contract PreflightSwapRouter {
    address public POOL_MANAGER;
    address public WETH;

    constructor(address manager, address wrapped) {
        POOL_MANAGER = manager;
        WETH = wrapped;
    }

    function setPoolManager(address manager) external {
        POOL_MANAGER = manager;
    }

    function setWeth(address wrapped) external {
        WETH = wrapped;
    }
}

contract PreflightFactoryAdapter {
    address public immutable weth;

    constructor(address wrapped) {
        weth = wrapped;
    }
}

contract V4DeploymentPreflightHarness is DeployV4UserLiquidity {
    function validate(
        address governance,
        address treasury,
        IWETH9 weth,
        ArchStockRegistry registry,
        IUniswapV4PositionManager positionManager,
        IUniswapV4StateView stateView,
        IPermit2AllowanceTransfer permit2,
        ArchV4PositionLocker locker,
        ArchV4SwapRouterAdapter swapRouter
    ) external view {
        _validateDependencies(
            governance, treasury, weth, registry, positionManager, stateView, permit2, locker, swapRouter
        );
    }
}

contract V4DeploymentPreflightTest is Test {
    V4DeploymentPreflightHarness private script;
    address private governance;
    address payable private treasury;
    MockWETH private weth;
    ArchStockRegistry private registry;
    PreflightContract private poolManager;
    PreflightContract private permit2;
    PreflightContract private executor;
    PreflightPositionManager private positionManager;
    PreflightStateView private stateView;
    PreflightLocker private locker;
    PreflightSwapRouter private swapRouter;

    function setUp() public {
        script = new V4DeploymentPreflightHarness();
        // Public fixture key only; run() must reject before any broadcast.
        governance = vm.addr(1);
        treasury = payable(makeAddr("release treasury"));
        vm.deal(governance, 1 ether);
        weth = new MockWETH();
        registry = new ArchStockRegistry(address(this));
        poolManager = new PreflightContract();
        permit2 = new PreflightContract();
        executor = new PreflightContract();
        registry.setStockSwapExecutor(address(executor));
        positionManager = new PreflightPositionManager(address(poolManager), address(permit2));
        stateView = new PreflightStateView(address(poolManager));
        locker = new PreflightLocker(governance, address(positionManager), address(poolManager));
        swapRouter = new PreflightSwapRouter(address(poolManager), address(weth));
    }

    function _validate() private view {
        script.validate(
            governance,
            treasury,
            IWETH9(address(weth)),
            registry,
            IUniswapV4PositionManager(address(positionManager)),
            IUniswapV4StateView(address(stateView)),
            IPermit2AllowanceTransfer(address(permit2)),
            ArchV4PositionLocker(address(locker)),
            ArchV4SwapRouterAdapter(address(swapRouter))
        );
    }

    function test_coherentDependenciesAcceptCustomExecutor() public view {
        _validate();
    }

    function test_unsetExecutorIsRejected() public {
        registry.setStockSwapExecutor(address(0));
        vm.expectRevert("v4 release: stock executor missing");
        _validate();
    }

    function test_executorWithoutCodeIsRejected() public {
        vm.etch(address(executor), hex"");
        vm.expectRevert("v4 release: stock executor missing");
        _validate();
    }

    function _assertRunRejected(string memory reason) private {
        vm.chainId(46630);
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("TESTNET_AMM_TREASURY", vm.toString(treasury));
        vm.setEnv("TESTNET_AMM_WETH", vm.toString(address(weth)));
        vm.setEnv("TESTNET_AMM_STOCK_REGISTRY", vm.toString(address(registry)));
        vm.setEnv("TESTNET_V4_POSITION_MANAGER", vm.toString(address(positionManager)));
        vm.setEnv("TESTNET_V4_STATE_VIEW", vm.toString(address(stateView)));
        vm.setEnv("TESTNET_PERMIT2", vm.toString(address(permit2)));
        vm.setEnv("TESTNET_V4_LOCKER", vm.toString(address(locker)));
        vm.setEnv("TESTNET_V4_SWAP_ROUTER", vm.toString(address(swapRouter)));
        uint64 nonceBefore = vm.getNonce(governance);
        uint256 balanceBefore = governance.balance;
        vm.expectRevert(bytes(reason));
        script.run();
        assertEq(vm.getNonce(governance), nonceBefore);
        assertEq(governance.balance, balanceBefore);
    }

    function test_unsetExecutorFailsRealRunBeforeBroadcast() public {
        registry.setStockSwapExecutor(address(0));
        _assertRunRejected("v4 release: stock executor missing");
    }

    function test_missingPoolFailsRealRunBeforeBroadcast() public {
        positionManager.setPoolManager(makeAddr("missing broadcast pool"));
        _assertRunRejected("v4 release: pool manager missing");
    }

    function test_wrongStateViewFailsRealRunBeforeBroadcast() public {
        stateView.setPoolManager(address(new PreflightContract()));
        _assertRunRejected("v4 release: state view pool");
    }

    function test_wrongPermit2FailsRealRunBeforeBroadcast() public {
        positionManager.setPermit2(address(new PreflightContract()));
        _assertRunRejected("v4 release: position manager permit2");
    }

    function test_unsetExecutorMakesExistingFactoryUnableToCreateTokens() public {
        registry.setStockSwapExecutor(address(0));
        MockERC20 stock = new MockERC20("Fixture stock", "STOCK");
        registry.setApproved(address(stock), true);
        ArchAdapterTokenFactory factory = new ArchAdapterTokenFactory(
            0,
            treasury,
            governance,
            IArchLaunchLiquidityAdapter(address(new PreflightFactoryAdapter(address(weth)))),
            ISwapRouter(address(swapRouter)),
            IWETH9(address(weth)),
            3000,
            0,
            registry
        );
        ArchAdapterTokenFactory.TokenParams memory token =
            ArchAdapterTokenFactory.TokenParams("Fixture token", "FIX", 1_000_000e18, 300, IERC20(address(stock)), 0);
        ArchAdapterTokenFactory.LiquidityParams memory noLiquidity =
            ArchAdapterTokenFactory.LiquidityParams(false, 0, 0, false, 0);
        vm.expectRevert("arch: zero executor");
        factory.createToken(token, noLiquidity);
        assertEq(factory.tokenCount(), 0);
    }

    function test_positionManagerWithMissingPoolIsRejected() public {
        positionManager.setPoolManager(makeAddr("missing pool manager"));
        vm.expectRevert("v4 release: pool manager missing");
        _validate();
    }

    function test_stateViewFromAnotherPoolIsRejected() public {
        stateView.setPoolManager(address(new PreflightContract()));
        vm.expectRevert("v4 release: state view pool");
        _validate();
    }

    function test_positionManagerWithDifferentPermit2IsRejected() public {
        positionManager.setPermit2(address(new PreflightContract()));
        vm.expectRevert("v4 release: position manager permit2");
        _validate();
    }

    function test_insufficientSignerBalanceIsRejected() public {
        vm.deal(governance, 0.02 ether - 1);
        vm.expectRevert("v4 release: signer balance");
        _validate();
    }

    function test_minimumSignerBalanceIsAccepted() public {
        vm.deal(governance, 0.02 ether);
        _validate();
    }

    function test_zeroSignerIsRejected() public {
        governance = address(0);
        vm.expectRevert("v4 release: signer balance");
        _validate();
    }

    function test_zeroTreasuryIsRejected() public {
        treasury = payable(address(0));
        vm.expectRevert("v4 release: zero treasury");
        _validate();
    }

    function test_wrongLockerAuthorityIsRejected() public {
        locker.setOwner(makeAddr("different governance"));
        vm.expectRevert("v4 release: locker authority");
        _validate();
    }

    function test_wrongLockerPositionManagerIsRejected() public {
        locker.setPositionManager(address(new PreflightContract()));
        vm.expectRevert("v4 release: locker manager");
        _validate();
    }

    function test_wrongLockerPoolIsRejected() public {
        locker.setPoolManager(address(new PreflightContract()));
        vm.expectRevert("v4 release: locker pool");
        _validate();
    }

    function test_wrongSwapPoolIsRejected() public {
        swapRouter.setPoolManager(address(new PreflightContract()));
        vm.expectRevert("v4 release: swap pool");
        _validate();
    }

    function test_wrongSwapWethIsRejected() public {
        swapRouter.setWeth(address(new MockWETH()));
        vm.expectRevert("v4 release: swap weth");
        _validate();
    }
}
