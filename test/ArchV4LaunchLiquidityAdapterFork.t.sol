// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchV4LaunchLiquidityAdapter} from "../src/ArchV4LaunchLiquidityAdapter.sol";
import {ArchV4SwapRouterAdapter} from "../src/ArchV4SwapRouterAdapter.sol";
import {ArchV2SwapRouterAdapter} from "../src/ArchV2SwapRouterAdapter.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {IUniswapV4PositionManager as LockerV4PositionManager} from "@archliquid/lockers/interfaces/IUniswapV4.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {IArchLaunchLiquidityAdapter, IArchLaunchRegistry} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {
    IPermit2AllowanceTransfer,
    IUniswapV4PoolManager,
    IUniswapV4PositionManager,
    IUniswapV4StateView,
    PoolKey
} from "../src/interfaces/IUniswapV4.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {MockERC20, MockWETH} from "./mocks/Mocks.sol";
import {UniswapV2Artifacts} from "../script/lib/UniswapV2Artifacts.sol";

contract ArchV4LaunchLiquidityAdapterForkTest is Test {
    IUniswapV4PositionManager private constant POSITION_MANAGER =
        IUniswapV4PositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IUniswapV4StateView private constant STATE_VIEW = IUniswapV4StateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    IPermit2AllowanceTransfer private constant PERMIT2 =
        IPermit2AllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    modifier liveV4Fork() {
        vm.skip(address(POSITION_MANAGER).code.length == 0, "requires Robinhood testnet V4 fork");
        _;
    }

    function test_seedAndLockAgainstLiveTestnetV4Stack() public liveV4Fork {
        MockERC20 token = new MockERC20("Arch V4 Fork", "AV4F");
        MockWETH weth = new MockWETH();
        ArchV4PositionLocker locker = new ArchV4PositionLocker(
            0, payable(makeAddr("treasury")), LockerV4PositionManager(address(POSITION_MANAGER)), address(this)
        );
        ArchV4LaunchLiquidityAdapter adapter = new ArchV4LaunchLiquidityAdapter(
            POSITION_MANAGER, STATE_VIEW, PERMIT2, IERC20(address(weth)), locker, address(this)
        );
        adapter.bindLaunchers(address(this), IArchLaunchRegistry(address(0)));
        locker.setFeeExempt(address(adapter), true);

        uint256 tokenAmount = 1_000_000e18;
        uint256 wethAmount = 1 ether;
        token.mint(address(this), tokenAmount);
        vm.deal(address(this), wethAmount);
        weth.deposit{value: wethAmount}();
        token.approve(address(adapter), tokenAmount);
        weth.approve(address(adapter), wethAmount);

        uint64 unlockTime = uint64(block.timestamp + 180 days);
        IArchLaunchLiquidityAdapter.SeedResult memory result = adapter.seed(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(token),
                tokenAmount: tokenAmount,
                wethAmount: wethAmount,
                lockOwner: address(this),
                unlockTime: unlockTime,
                permanent: false
            })
        );

        assertEq(result.market, POSITION_MANAGER.poolManager());
        assertEq(result.positionManager, address(POSITION_MANAGER));
        assertGt(result.positionIdOrAmount, 0);
        assertGt(result.tokenUsed, 0);
        assertGt(result.wethUsed, 0);
        assertLe(result.tokenUsed, tokenAmount);
        assertLe(result.wethUsed, wethAmount);
        assertEq(POSITION_MANAGER.ownerOf(result.positionIdOrAmount), address(locker));
        assertGt(POSITION_MANAGER.getPositionLiquidity(result.positionIdOrAmount), 0);

        (PoolKey memory key,) = POSITION_MANAGER.getPoolAndPositionInfo(result.positionIdOrAmount);
        assertEq(keccak256(abi.encode(key)), result.poolId);
        assertEq(key.fee, 3000);
        assertEq(key.tickSpacing, 60);
        assertEq(key.hooks, address(0));
        (uint160 sqrtPriceX96,,,) = STATE_VIEW.getSlot0(result.poolId);
        assertGt(sqrtPriceX96, 0);

        ArchV4PositionLocker.Lock memory created = locker.getLock(result.lockId);
        assertEq(created.tokenId, result.positionIdOrAmount);
        assertEq(created.owner, address(this));
        assertEq(created.unlockTime, unlockTime);
        assertFalse(created.withdrawn);

        // Any rounding dust is explicitly returned to the launcher; the
        // adapter itself retains no token or WETH balance.
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(this)), tokenAmount - result.tokenUsed);
        assertEq(weth.balanceOf(address(this)), wethAmount - result.wethUsed);
    }

    function test_taxedBuySellAndDistributionAgainstLiveV4PoolManager() public liveV4Fork {
        MockWETH weth = new MockWETH();
        MockERC20 stock = new MockERC20("Mock Stock", "mSTOCK");

        // The stock purchase leg uses the pinned functional V2 fixture while
        // the launched token itself trades through the live V4 PoolManager.
        IUniswapV2Factory v2Factory = IUniswapV2Factory(UniswapV2Artifacts.deployFactory(address(this)));
        IUniswapV2Router02 v2Router =
            IUniswapV2Router02(UniswapV2Artifacts.deployRouter(address(v2Factory), address(weth)));
        ArchV2SwapRouterAdapter stockRouter = new ArchV2SwapRouterAdapter(v2Factory);
        ArchV4SwapRouterAdapter v4Router = new ArchV4SwapRouterAdapter(
            IUniswapV4PoolManager(POSITION_MANAGER.poolManager()),
            IERC20(address(weth)),
            IERC20(address(stock)),
            ISwapRouter(address(stockRouter))
        );

        ArchTreasury treasury = new ArchTreasury(address(this));
        ArchStockSwapExecutor stockExecutor = new ArchStockSwapExecutor(IERC20(address(weth)), address(v4Router));
        ArchToken launchToken = new ArchToken(
            "Arch V4 Launch",
            "AV4",
            1_000_000e18,
            300,
            IERC20(address(stock)),
            ArchToken.DexConfig({
                swapRouter: ISwapRouter(address(v4Router)),
                weth: IWETH9(address(weth)),
                tokenPoolFee: 3000,
                stockPoolFee: 0,
                stockSwapExecutor: stockExecutor
            }),
            payable(address(treasury)),
            address(this),
            0,
            address(this)
        );
        assertEq(launchToken.TAX_BPS(), 300);
        assertEq(address(launchToken.STOCK()), address(stock));

        vm.deal(address(this), 60 ether);
        weth.deposit{value: 60 ether}();
        stock.mint(address(this), 1_000_000e18);
        weth.approve(address(v2Router), type(uint256).max);
        stock.approve(address(v2Router), type(uint256).max);
        v2Router.addLiquidity(
            address(stock),
            address(weth),
            1_000_000e18,
            20 ether,
            1_000_000e18,
            20 ether,
            address(0xdEaD),
            block.timestamp
        );

        ArchV4PositionLocker locker = new ArchV4PositionLocker(
            0, payable(makeAddr("treasury2")), LockerV4PositionManager(address(POSITION_MANAGER)), address(this)
        );
        ArchV4LaunchLiquidityAdapter liquidityAdapter = new ArchV4LaunchLiquidityAdapter(
            POSITION_MANAGER, STATE_VIEW, PERMIT2, IERC20(address(weth)), locker, address(this)
        );
        liquidityAdapter.bindLaunchers(address(this), IArchLaunchRegistry(address(0)));
        locker.setFeeExempt(address(liquidityAdapter), true);
        launchToken.approve(address(liquidityAdapter), type(uint256).max);
        weth.approve(address(liquidityAdapter), type(uint256).max);

        IArchLaunchLiquidityAdapter.SeedResult memory seeded = liquidityAdapter.seed(
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

        address alice = makeAddr("v4 alice");
        address bob = makeAddr("v4 bob");
        launchToken.transfer(alice, 500_000e18);
        launchToken.finalizeWiring();

        vm.startPrank(alice);
        launchToken.approve(address(v4Router), type(uint256).max);
        uint256 wethOut = v4Router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(launchToken),
                tokenOut: address(weth),
                fee: 3000,
                recipient: alice,
                amountIn: 10_000e18,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertGt(wethOut, 0);
        assertEq(launchToken.balanceOf(address(launchToken)), 300e18);

        weth.transfer(bob, 1 ether);
        vm.startPrank(bob);
        weth.approve(address(v4Router), type(uint256).max);
        uint256 bobBefore = launchToken.balanceOf(bob);
        uint256 netBought = v4Router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(launchToken),
                fee: 3000,
                recipient: bob,
                amountIn: 1 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertEq(launchToken.balanceOf(bob) - bobBefore, netBought);
        assertGt(launchToken.balanceOf(address(launchToken)), 300e18);

        uint256 treasuryBefore = address(treasury).balance;
        launchToken.processDistribution(1, 1);
        assertGt(address(treasury).balance, treasuryBefore);
        assertGt(launchToken.totalDistributed(), 0);
        uint256 aliceClaimable = launchToken.withdrawableDividendOf(alice);
        assertGt(aliceClaimable, 0);
        uint256 aliceStockBefore = stock.balanceOf(alice);
        vm.prank(alice);
        launchToken.claim();
        assertEq(stock.balanceOf(alice) - aliceStockBefore, aliceClaimable);
    }
}
