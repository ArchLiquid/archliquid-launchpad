// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {IUniswapV2Factory as LockerV2Factory} from "@archliquid/lockers/interfaces/IUniswapV2.sol";
import {ArchV2LaunchLiquidityAdapter} from "../src/ArchV2LaunchLiquidityAdapter.sol";
import {ArchV2SwapRouterAdapter} from "../src/ArchV2SwapRouterAdapter.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {IArchLaunchLiquidityAdapter, IArchLaunchRegistry} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {MockERC20, MockWETH} from "./mocks/Mocks.sol";
import {UniswapV2Artifacts} from "../script/lib/UniswapV2Artifacts.sol";

contract ArchV2LaunchLiquidityAdapterTest is Test {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant LOCK_FEE = 0.02 ether;

    MockWETH private weth;
    MockERC20 private token;
    IUniswapV2Factory private factory;
    IUniswapV2Router02 private router;
    ArchLiquidityLocker private locker;
    ArchV2LaunchLiquidityAdapter private adapter;

    address private creator = makeAddr("creator");

    function setUp() public {
        weth = new MockWETH();
        token = new MockERC20("Launch Token", "LCH");
        factory = IUniswapV2Factory(UniswapV2Artifacts.deployFactory(address(this)));
        router = IUniswapV2Router02(UniswapV2Artifacts.deployRouter(address(factory), address(weth)));
        locker =
            new ArchLiquidityLocker(LOCK_FEE, payable(address(this)), LockerV2Factory(address(factory)), address(this));
        adapter = new ArchV2LaunchLiquidityAdapter(router, locker, address(this));

        // This test contract stands in for the versioned token factory.
        adapter.bindLaunchers(address(this), IArchLaunchRegistry(address(0)));
        locker.setFeeExempt(address(adapter), true);

        token.mint(address(this), 1_000_000e18);
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        token.approve(address(adapter), type(uint256).max);
        weth.approve(address(adapter), type(uint256).max);
    }

    function test_seedLocksRealV2LiquidityAtExactRatio() public {
        uint256 tokenAmount = 100_000e18;
        uint256 wethAmount = 10 ether;
        uint64 unlockTime = uint64(block.timestamp + 180 days);

        IArchLaunchLiquidityAdapter.SeedResult memory result = adapter.seed(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(token),
                tokenAmount: tokenAmount,
                wethAmount: wethAmount,
                lockOwner: creator,
                unlockTime: unlockTime,
                permanent: false
            })
        );

        address pair = factory.getPair(address(token), address(weth));
        assertEq(result.market, pair);
        assertEq(result.positionManager, pair);
        assertEq(result.poolId, bytes32(uint256(uint160(pair))));
        assertTrue(locker.isCanonicalPair(pair));
        assertGt(result.positionIdOrAmount, 0);
        assertEq(IERC20(pair).balanceOf(address(locker)), result.positionIdOrAmount);
        assertEq(IERC20(pair).balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);

        ArchLiquidityLocker.Lock memory created = locker.getLock(result.lockId);
        assertEq(created.token, pair);
        assertEq(created.owner, creator);
        assertEq(created.amount, result.positionIdOrAmount);
        assertEq(created.unlockTime, unlockTime);

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        if (IUniswapV2Pair(pair).token0() == address(token)) {
            assertEq(reserve0, tokenAmount);
            assertEq(reserve1, wethAmount);
        } else {
            assertEq(reserve0, wethAmount);
            assertEq(reserve1, tokenAmount);
        }
    }

    function test_seedPermanentMintsLpDirectlyToDeadAddress() public {
        IArchLaunchLiquidityAdapter.SeedResult memory result = adapter.seed(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(token),
                tokenAmount: 25_000e18,
                wethAmount: 2 ether,
                lockOwner: address(0),
                unlockTime: 0,
                permanent: true
            })
        );

        assertEq(result.lockId, type(uint256).max);
        assertEq(IERC20(result.market).balanceOf(DEAD), result.positionIdOrAmount);
        assertEq(IERC20(result.market).balanceOf(address(adapter)), 0);
    }

    function test_seedRejectsUnauthorizedCaller() public {
        vm.prank(makeAddr("unregistered"));
        vm.expectRevert("v2 adapter: unauthorized");
        adapter.seed(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(token),
                tokenAmount: 1e18,
                wethAmount: 1e18,
                lockOwner: creator,
                unlockTime: uint64(block.timestamp + 180 days),
                permanent: false
            })
        );
    }

    function test_bindLaunchersCannotBeChanged() public {
        vm.expectRevert("v2 adapter: already bound");
        adapter.bindLaunchers(address(this), IArchLaunchRegistry(address(0)));
    }

    function test_realV2TaxedBuySellAndDistributionLifecycle() public {
        MockERC20 stock = new MockERC20("Mock Stock", "mSTOCK");
        ArchV2SwapRouterAdapter swapAdapter = new ArchV2SwapRouterAdapter(factory);
        ArchTreasury treasury = new ArchTreasury(address(this));
        ArchStockSwapExecutor stockExecutor = new ArchStockSwapExecutor(IERC20(address(weth)), address(swapAdapter));

        ArchToken launchToken = new ArchToken(
            "Arch V2 Launch",
            "AV2",
            1_000_000e18,
            300,
            IERC20(address(stock)),
            ArchToken.DexConfig({
                swapRouter: ISwapRouter(address(swapAdapter)),
                weth: IWETH9(address(weth)),
                tokenPoolFee: 0,
                stockPoolFee: 0,
                stockSwapExecutor: stockExecutor
            }),
            payable(address(treasury)),
            address(this),
            0,
            address(this)
        );

        // Seed the stock/WETH output route on the same functional V2 fixture.
        stock.mint(address(this), 1_000_000e18);
        stock.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(stock), address(weth), 1_000_000e18, 20 ether, 1_000_000e18, 20 ether, DEAD, block.timestamp
        );

        launchToken.approve(address(adapter), type(uint256).max);
        IArchLaunchLiquidityAdapter.SeedResult memory seeded = adapter.seed(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(launchToken),
                tokenAmount: 200_000e18,
                wethAmount: 20 ether,
                lockOwner: address(0),
                unlockTime: 0,
                permanent: true
            })
        );
        launchToken.addMarketPair(seeded.market);
        launchToken.setDividendExempt(address(this));
        launchToken.setDividendExempt(address(launchToken));

        address alice = makeAddr("v2 alice");
        address bob = makeAddr("v2 bob");
        launchToken.transfer(alice, 500_000e18);
        launchToken.finalizeWiring();

        // A taxed sell succeeds because the adapter prices the amount that the
        // pair actually receives (9,700 after the 3% transfer tax).
        vm.startPrank(alice);
        launchToken.approve(address(swapAdapter), type(uint256).max);
        uint256 wethOut = swapAdapter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(launchToken),
                tokenOut: address(weth),
                fee: 0,
                recipient: alice,
                amountIn: 10_000e18,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertGt(wethOut, 0);
        assertEq(launchToken.balanceOf(address(launchToken)), 300e18);

        // A buy also reports the recipient's net amount after tax, not the
        // pair's gross output, so the minimum-output check protects the user.
        weth.transfer(bob, 1 ether);
        vm.startPrank(bob);
        weth.approve(address(swapAdapter), type(uint256).max);
        uint256 tokenBefore = launchToken.balanceOf(bob);
        uint256 netBought = swapAdapter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(launchToken),
                fee: 0,
                recipient: bob,
                amountIn: 1 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertEq(launchToken.balanceOf(bob) - tokenBefore, netBought);
        assertGt(launchToken.balanceOf(address(launchToken)), 300e18);

        uint256 treasuryBefore = address(treasury).balance;
        launchToken.processDistribution(1, 1);
        assertGt(address(treasury).balance, treasuryBefore);
        assertGt(launchToken.totalDistributed(), 0);
        assertGt(launchToken.withdrawableDividendOf(alice), 0);
    }
}
