// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchAdapterLaunchpad} from "../src/ArchAdapterLaunchpad.sol";
import {ArchAdapterPresale} from "../src/ArchAdapterPresale.sol";
import {ArchAdapterBondingCurve} from "../src/ArchAdapterBondingCurve.sol";
import {ArchAdapterPresaleDeployer} from "../src/ArchAdapterPresaleDeployer.sol";
import {ArchAdapterCurveDeployer} from "../src/ArchAdapterCurveDeployer.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {IUniswapV4PositionManager as LockerV4PositionManager} from "@archliquid/lockers/interfaces/IUniswapV4.sol";
import {ArchV4LaunchLiquidityAdapter} from "../src/ArchV4LaunchLiquidityAdapter.sol";
import {ArchUserLiquidityProvisioner} from "../src/ArchUserLiquidityProvisioner.sol";
import {ArchV4SwapRouterAdapter} from "../src/ArchV4SwapRouterAdapter.sol";
import {ArchV2SwapRouterAdapter} from "../src/ArchV2SwapRouterAdapter.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {IArchLaunchRegistry} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {
    IPermit2AllowanceTransfer,
    IUniswapV4PoolManager,
    IUniswapV4PositionManager,
    IUniswapV4StateView
} from "../src/interfaces/IUniswapV4.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {MockERC20, MockWETH} from "./mocks/Mocks.sol";
import {UniswapV2Artifacts} from "../script/lib/UniswapV2Artifacts.sol";

contract ArchAdapterLaunchpadV4ForkTest is Test {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant LISTING_FEE = 0.01 ether;
    uint256 private constant SUPPLY = 1_000_000e18;
    uint24 private constant V4_FEE = 3000;

    IUniswapV4PositionManager private constant POSITION_MANAGER =
        IUniswapV4PositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IUniswapV4StateView private constant STATE_VIEW = IUniswapV4StateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    IPermit2AllowanceTransfer private constant PERMIT2 =
        IPermit2AllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    ArchTreasury private treasury;
    MockWETH private weth;
    MockERC20 private stock;
    ArchV4PositionLocker private locker;
    ArchV4LaunchLiquidityAdapter private liquidityAdapter;
    ArchV4SwapRouterAdapter private swapAdapter;
    ArchAdapterLaunchpad private launchpad;

    address private keeper = makeAddr("keeper");
    address private creator = makeAddr("creator");
    address private alice = makeAddr("alice");
    uint64 private start;
    uint64 private end;
    bool private liveFork;

    function setUp() public {
        liveFork = address(POSITION_MANAGER).code.length > 0;
        vm.skip(!liveFork, "requires Robinhood testnet V4 fork");

        vm.deal(address(this), 200 ether);
        vm.deal(creator, 20 ether);
        vm.deal(alice, 100 ether);

        treasury = new ArchTreasury(address(this));
        weth = new MockWETH();
        stock = new MockERC20("Mock Stock", "mSTOCK");

        // V4 launches use the live testnet PoolManager. The distribution's
        // direct WETH-to-stock leg uses a deterministic local V2 fixture.
        IUniswapV2Factory v2Factory = IUniswapV2Factory(UniswapV2Artifacts.deployFactory(address(this)));
        IUniswapV2Router02 v2Router =
            IUniswapV2Router02(UniswapV2Artifacts.deployRouter(address(v2Factory), address(weth)));
        ArchV2SwapRouterAdapter stockRouter = new ArchV2SwapRouterAdapter(v2Factory);
        swapAdapter = new ArchV4SwapRouterAdapter(
            IUniswapV4PoolManager(POSITION_MANAGER.poolManager()),
            IERC20(address(weth)),
            IERC20(address(stock)),
            ISwapRouter(address(stockRouter))
        );

        ArchStockRegistry registry = new ArchStockRegistry(address(this));
        registry.setApproved(address(stock), true);
        ArchStockSwapExecutor executor = new ArchStockSwapExecutor(IERC20(address(weth)), address(swapAdapter));
        registry.setStockSwapExecutor(address(executor));

        locker = new ArchV4PositionLocker(
            0, payable(address(treasury)), LockerV4PositionManager(address(POSITION_MANAGER)), address(this)
        );
        liquidityAdapter = new ArchV4LaunchLiquidityAdapter(
            POSITION_MANAGER, STATE_VIEW, PERMIT2, IERC20(address(weth)), locker, address(this)
        );
        ArchUserLiquidityProvisioner provisioner = new ArchUserLiquidityProvisioner(liquidityAdapter);
        ArchAdapterPresaleDeployer presaleDeployer = new ArchAdapterPresaleDeployer();
        ArchAdapterCurveDeployer curveDeployer = new ArchAdapterCurveDeployer();
        launchpad = new ArchAdapterLaunchpad(
            LISTING_FEE,
            payable(address(treasury)),
            liquidityAdapter,
            ISwapRouter(address(swapAdapter)),
            IWETH9(address(weth)),
            V4_FEE,
            0,
            keeper,
            registry,
            presaleDeployer,
            curveDeployer
        );
        presaleDeployer.setLaunchpad(address(launchpad));
        curveDeployer.setLaunchpad(address(launchpad));
        liquidityAdapter.bindLiquidityProvisioner(address(provisioner));
        liquidityAdapter.bindLaunchers(address(0), IArchLaunchRegistry(address(launchpad)));
        locker.setFeeExempt(address(liquidityAdapter), true);

        stock.mint(address(this), 2_000_000e18);
        weth.deposit{value: 50 ether}();
        stock.approve(address(v2Router), type(uint256).max);
        weth.approve(address(v2Router), type(uint256).max);
        v2Router.addLiquidity(
            address(stock), address(weth), 1_000_000e18, 20 ether, 1_000_000e18, 20 ether, DEAD, block.timestamp
        );

        start = uint64(block.timestamp + 1 hours);
        end = uint64(block.timestamp + 1 days);
    }

    function test_presaleFinalizesLocksAndTradesThroughLiveV4Stack() public {
        ArchAdapterPresale.TokenConfig memory tokenConfig = ArchAdapterPresale.TokenConfig({
            name: "V4 Presale",
            symbol: "V4P",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterPresale.SaleConfig memory saleConfig = ArchAdapterPresale.SaleConfig({
            softCap: 1 ether,
            hardCap: 2 ether,
            start: start,
            end: end,
            perWalletCap: 2 ether,
            salePct: 50,
            lpPct: 40,
            poolFee: V4_FEE,
            lpLockDuration: 180 days,
            teamCliff: end + 30 days,
            teamEnd: end + 365 days
        });

        vm.prank(creator);
        ArchAdapterPresale presale =
            ArchAdapterPresale(payable(launchpad.createPresale{value: LISTING_FEE}(tokenConfig, saleConfig)));
        assertTrue(launchpad.isLaunch(address(presale)));

        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 2 ether}();
        presale.finalize();

        ArchToken token = presale.token();
        assertEq(token.TAX_BPS(), 300);
        assertEq(address(token.STOCK()), address(stock));
        ArchV4PositionLocker.Lock memory created = locker.getLock(0);
        assertEq(POSITION_MANAGER.ownerOf(created.tokenId), address(locker));
        assertEq(created.owner, creator);
        assertEq(presale.pair(), POSITION_MANAGER.poolManager());
        assertTrue(token.isMarketPair(POSITION_MANAGER.poolManager()));
        assertTrue(token.wired());

        vm.prank(alice);
        presale.claim();
        vm.startPrank(alice);
        token.approve(address(swapAdapter), type(uint256).max);
        uint256 wethOut = swapAdapter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: address(weth),
                fee: V4_FEE,
                recipient: alice,
                amountIn: 10_000e18,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertGt(wethOut, 0);
        assertGt(token.balanceOf(address(token)), 0);

        vm.prank(keeper);
        token.processDistribution(1, 1);
        assertGt(token.totalDistributed(), 0);
        uint256 aliceClaimable = token.withdrawableDividendOf(alice);
        assertGt(aliceClaimable, 0);
        uint256 aliceStockBefore = stock.balanceOf(alice);
        vm.prank(alice);
        token.claim();
        assertEq(stock.balanceOf(alice) - aliceStockBefore, aliceClaimable);
    }

    function test_curveGraduatesIntoPermanentLiveV4Position() public {
        ArchAdapterBondingCurve.TokenConfig memory tokenConfig = ArchAdapterBondingCurve.TokenConfig({
            name: "V4 Curve",
            symbol: "V4C",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterBondingCurve.CurveConfig memory curveConfig = ArchAdapterBondingCurve.CurveConfig({
            curvePct: 80, virtualEth: 1 ether, gradEth: 0.99 ether, poolFee: V4_FEE
        });

        vm.prank(creator);
        ArchAdapterBondingCurve curve =
            ArchAdapterBondingCurve(payable(launchpad.createCurve{value: LISTING_FEE}(tokenConfig, curveConfig)));
        uint256 nextId = POSITION_MANAGER.nextTokenId();

        assertEq(curve.graduationBuyAmount(), 1 ether);

        vm.prank(alice);
        curve.buy{value: 1 ether}(0);

        assertTrue(curve.graduated());
        assertEq(POSITION_MANAGER.ownerOf(nextId), DEAD);
        assertGt(POSITION_MANAGER.getPositionLiquidity(nextId), 0);
        assertEq(curve.pair(), POSITION_MANAGER.poolManager());
        assertTrue(curve.token().isMarketPair(POSITION_MANAGER.poolManager()));
        assertEq(curve.token().balanceOf(address(curve)), 0);
    }
}
