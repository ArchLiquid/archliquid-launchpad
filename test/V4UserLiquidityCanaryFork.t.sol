// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {IUniswapV4PositionManager as LockerPositionManager} from "@archliquid/lockers/interfaces/IUniswapV4.sol";
import {ArchV4LaunchLiquidityAdapter} from "../src/ArchV4LaunchLiquidityAdapter.sol";
import {ArchV4UserLiquidityProvisioner} from "../src/ArchV4UserLiquidityProvisioner.sol";
import {ArchV4SwapRouterAdapter} from "../src/ArchV4SwapRouterAdapter.sol";
import {ArchAdapterTokenFactory} from "../src/ArchAdapterTokenFactory.sol";
import {IArchLaunchRegistry} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {
    IUniswapV4PositionManager,
    IUniswapV4StateView,
    IUniswapV4PoolManager,
    IPermit2AllowanceTransfer
} from "../src/interfaces/IUniswapV4.sol";
import {V4UserLiquidityCanary} from "../script/CanaryV4UserLiquidity.s.sol";
import {MockERC20, MockWETH, MockV3Router} from "./mocks/Mocks.sol";

/// @dev A funded operator avoids relying on prank's CREATE balance semantics.
contract V4CanaryOperator {
    receive() external payable {}

    function run(ArchAdapterTokenFactory factory, IERC20 stock, uint256 maximumFactoryFee)
        external
        returns (V4UserLiquidityCanary)
    {
        return new V4UserLiquidityCanary{value: factory.FEE() + 0.002 ether}(
            address(this), factory, stock, maximumFactoryFee
        );
    }
}

/// @dev Sends one extra wei to the canary during its constructor. The late
///      accounting check must revert the entire canary, including both seeds.
contract V4CanarySurplusTreasury {
    address payable private immutable _canary;

    constructor(address canary) {
        _canary = payable(canary);
    }

    receive() external payable {
        (bool sent,) = _canary.call{value: 1}("");
        require(sent, "canary fixture: surplus transfer");
    }
}

/// @dev Uses real PositionManager/PoolManager/StateView/Permit2 on a read-only
///      Robinhood fork. All fresh release contracts and mutations stay local.
contract V4UserLiquidityCanaryForkTest is Test {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant FACTORY_FEE = 0.0004 ether;
    uint256 private constant VALUE = FACTORY_FEE + 0.002 ether;
    IUniswapV4PositionManager private constant POSITION_MANAGER =
        IUniswapV4PositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IUniswapV4StateView private constant STATE_VIEW = IUniswapV4StateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    IPermit2AllowanceTransfer private constant PERMIT2 =
        IPermit2AllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    MockWETH private weth;
    MockERC20 private stock;
    ArchV4PositionLocker private locker;
    ArchV4LaunchLiquidityAdapter private adapter;
    ArchV4UserLiquidityProvisioner private provisioner;
    ArchAdapterTokenFactory private factory;
    address private provider;
    address private treasury = makeAddr("canary treasury");

    receive() external payable {}

    function setUp() public {
        vm.skip(block.chainid != 46630 || address(POSITION_MANAGER).code.length == 0, "requires Robinhood V4 fork");
        vm.deal(address(this), 20 ether);
        provider = address(new V4CanaryOperator());
        vm.deal(provider, 1 ether);
        weth = new MockWETH();
        stock = new MockERC20("Canary Stock", "cSTOCK");
        MockV3Router stockRouter = new MockV3Router();
        ArchV4SwapRouterAdapter swapRouter = new ArchV4SwapRouterAdapter(
            IUniswapV4PoolManager(POSITION_MANAGER.poolManager()),
            IERC20(address(weth)),
            IERC20(address(stock)),
            ISwapRouter(address(stockRouter))
        );
        ArchStockRegistry registry = new ArchStockRegistry(address(this));
        registry.setApproved(address(stock), true);
        ArchStockSwapExecutor executor = new ArchStockSwapExecutor(IERC20(address(weth)), address(swapRouter));
        registry.setStockSwapExecutor(address(executor));
        locker = new ArchV4PositionLocker(
            0.01 ether, payable(treasury), LockerPositionManager(address(POSITION_MANAGER)), address(this)
        );
        adapter = new ArchV4LaunchLiquidityAdapter(
            POSITION_MANAGER, STATE_VIEW, PERMIT2, IERC20(address(weth)), locker, address(this)
        );
        provisioner = new ArchV4UserLiquidityProvisioner(adapter);
        factory = new ArchAdapterTokenFactory(
            FACTORY_FEE,
            payable(treasury),
            address(this),
            adapter,
            ISwapRouter(address(swapRouter)),
            IWETH9(address(weth)),
            3000,
            0,
            registry
        );
        adapter.bindLiquidityProvisioner(address(provisioner));
        adapter.bindLaunchers(address(factory), IArchLaunchRegistry(address(0)));
        locker.setFeeExempt(address(adapter), true);
    }

    function test_freshReleaseDynamicFeeAndDonationsPreserveCustodyAndBalances() public {
        weth.deposit{value: 5 ether}();
        weth.transfer(address(provisioner), 2 ether);
        weth.transfer(address(adapter), 3 ether);
        uint256 treasuryBefore = treasury.balance;
        uint256 positionBefore = POSITION_MANAGER.nextTokenId();
        V4UserLiquidityCanary canary = _run();

        assertEq(factory.tokenCount(), 1);
        assertEq(factory.allTokens(0), address(canary.TOKEN()));
        assertEq(treasury.balance, treasuryBefore + FACTORY_FEE);
        assertEq(POSITION_MANAGER.nextTokenId(), positionBefore + 2);
        assertEq(POSITION_MANAGER.ownerOf(canary.TIMED_POSITION()), address(locker));
        assertEq(POSITION_MANAGER.ownerOf(canary.PERMANENT_POSITION()), DEAD);
        assertEq(locker.getLock(canary.LOCK_ID()).owner, provider);
        assertEq(locker.lockCount(), 1);
        assertEq(weth.balanceOf(address(provisioner)), 2 ether);
        assertEq(weth.balanceOf(address(adapter)), 3 ether);
        assertGe(canary.TOKEN().balanceOf(provider), 800_000e18);
        assertEq(canary.TOKEN().balanceOf(address(canary)), 0);
        assertEq(address(canary).balance, 0);
        assertLe(1 ether - provider.balance, VALUE);
        assertGt(1 ether - provider.balance, FACTORY_FEE);
    }

    function test_usedFactoryCannotCreateAnotherCanary() public {
        _run();
        uint256 positionBefore = POSITION_MANAGER.nextTokenId();
        uint256 balanceBefore = provider.balance;
        vm.expectRevert("v4 canary: release not fresh");
        _run();
        assertEq(factory.tokenCount(), 1);
        assertEq(POSITION_MANAGER.nextTokenId(), positionBefore);
        assertEq(locker.lockCount(), 1);
        assertEq(provider.balance, balanceBefore);
    }

    function test_anotherApprovedStockWithGenericExecutorRemainsSupported() public {
        MockERC20 anotherStock = new MockERC20("Another Approved Stock", "OTHER");
        factory.STOCK_REGISTRY().setApproved(address(anotherStock), true);
        V4UserLiquidityCanary canary =
            V4CanaryOperator(payable(provider)).run(factory, IERC20(address(anotherStock)), FACTORY_FEE);
        assertEq(address(canary.TOKEN().STOCK()), address(anotherStock));
        assertEq(factory.tokenCount(), 1);
        assertEq(locker.getLock(canary.LOCK_ID()).owner, provider);
    }

    function _run() private returns (V4UserLiquidityCanary) {
        return V4CanaryOperator(payable(provider)).run(factory, IERC20(address(stock)), FACTORY_FEE);
    }

    function test_postSeedingFailureRollsBackFactoryTreasuryPositionsAndLocks() public {
        uint256 positionBefore = POSITION_MANAGER.nextTokenId();
        uint256 treasuryBefore = treasury.balance;
        uint256 providerBefore = provider.balance;
        address expectedCanary = vm.computeCreateAddress(provider, vm.getNonce(provider));
        vm.etch(treasury, address(new V4CanarySurplusTreasury(expectedCanary)).code);

        // The surplus is detected after canonical positions, custody, approvals
        // and remaining tokens have all been checked. This fixture remains
        // independent of additional adapter-side NFT validation.
        vm.expectRevert("v4 canary: remaining eth");
        _run();

        assertEq(factory.tokenCount(), 0);
        assertEq(treasury.balance, treasuryBefore);
        assertEq(provider.balance, providerBefore);
        assertEq(POSITION_MANAGER.nextTokenId(), positionBefore);
        assertEq(locker.lockCount(), 0);
        assertEq(weth.balanceOf(address(provisioner)), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
    }
}
