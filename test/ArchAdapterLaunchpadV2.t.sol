// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchAdapterLaunchpad} from "../src/ArchAdapterLaunchpad.sol";
import {ArchAdapterPresale} from "../src/ArchAdapterPresale.sol";
import {ArchAdapterBondingCurve} from "../src/ArchAdapterBondingCurve.sol";
import {ArchAdapterPresaleDeployer} from "../src/ArchAdapterPresaleDeployer.sol";
import {ArchAdapterCurveDeployer} from "../src/ArchAdapterCurveDeployer.sol";
import {ArchAdapterTokenFactory} from "../src/ArchAdapterTokenFactory.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {IUniswapV2Factory as LockerV2Factory} from "@archliquid/lockers/interfaces/IUniswapV2.sol";
import {ArchV2LaunchLiquidityAdapter} from "../src/ArchV2LaunchLiquidityAdapter.sol";
import {ArchV2SwapRouterAdapter} from "../src/ArchV2SwapRouterAdapter.sol";
import {ArchUserLiquidityProvisioner} from "../src/ArchUserLiquidityProvisioner.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {IArchLaunchLiquidityAdapter, IArchLaunchRegistry} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {MockERC20, MockWETH} from "./mocks/Mocks.sol";
import {UniswapV2Artifacts} from "../script/lib/UniswapV2Artifacts.sol";

contract ArchAdapterLaunchpadV2Test is Test {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant LISTING_FEE = 0.01 ether;
    uint256 private constant FACTORY_FEE = 0.02 ether;
    uint256 private constant SUPPLY = 1_000_000e18;

    ArchTreasury private treasury;
    MockWETH private weth;
    MockERC20 private stock;
    IUniswapV2Factory private v2Factory;
    IUniswapV2Router02 private upstreamRouter;
    ArchLiquidityLocker private locker;
    ArchV2LaunchLiquidityAdapter private liquidityAdapter;
    ArchV2SwapRouterAdapter private swapAdapter;
    ArchUserLiquidityProvisioner private provisioner;
    ArchStockRegistry private registry;
    ArchAdapterTokenFactory private tokenFactory;
    ArchAdapterLaunchpad private launchpad;

    address private keeper = makeAddr("keeper");
    address private creator = makeAddr("creator");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    uint64 private start;
    uint64 private end;

    function setUp() public {
        vm.deal(address(this), 200 ether);
        vm.deal(creator, 20 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        treasury = new ArchTreasury(address(this));
        weth = new MockWETH();
        stock = new MockERC20("Mock Stock", "mSTOCK");
        v2Factory = IUniswapV2Factory(UniswapV2Artifacts.deployFactory(address(this)));
        upstreamRouter = IUniswapV2Router02(UniswapV2Artifacts.deployRouter(address(v2Factory), address(weth)));
        locker = new ArchLiquidityLocker(
            0.02 ether, payable(address(treasury)), LockerV2Factory(address(v2Factory)), address(this)
        );
        liquidityAdapter = new ArchV2LaunchLiquidityAdapter(upstreamRouter, locker, address(this));
        swapAdapter = new ArchV2SwapRouterAdapter(v2Factory);
        provisioner = new ArchUserLiquidityProvisioner(liquidityAdapter);

        registry = new ArchStockRegistry(address(this));
        registry.setApproved(address(stock), true);
        ArchStockSwapExecutor executor = new ArchStockSwapExecutor(IERC20(address(weth)), address(swapAdapter));
        registry.setStockSwapExecutor(address(executor));

        tokenFactory = new ArchAdapterTokenFactory(
            FACTORY_FEE,
            payable(address(treasury)),
            keeper,
            liquidityAdapter,
            ISwapRouter(address(swapAdapter)),
            IWETH9(address(weth)),
            0,
            0,
            registry
        );
        ArchAdapterPresaleDeployer presaleDeployer = new ArchAdapterPresaleDeployer();
        ArchAdapterCurveDeployer curveDeployer = new ArchAdapterCurveDeployer();
        launchpad = new ArchAdapterLaunchpad(
            LISTING_FEE,
            payable(address(treasury)),
            liquidityAdapter,
            ISwapRouter(address(swapAdapter)),
            IWETH9(address(weth)),
            0,
            0,
            keeper,
            registry,
            presaleDeployer,
            curveDeployer
        );
        presaleDeployer.setLaunchpad(address(launchpad));
        curveDeployer.setLaunchpad(address(launchpad));
        liquidityAdapter.bindLiquidityProvisioner(address(provisioner));
        liquidityAdapter.bindLaunchers(address(tokenFactory), IArchLaunchRegistry(address(launchpad)));
        locker.setFeeExempt(address(liquidityAdapter), true);

        // Direct WETH-to-stock liquidity for ArchToken's distribution path.
        stock.mint(address(this), 2_000_000e18);
        weth.deposit{value: 50 ether}();
        stock.approve(address(upstreamRouter), type(uint256).max);
        weth.approve(address(upstreamRouter), type(uint256).max);
        upstreamRouter.addLiquidity(
            address(stock), address(weth), 1_000_000e18, 20 ether, 1_000_000e18, 20 ether, DEAD, block.timestamp
        );

        start = uint64(block.timestamp + 1 hours);
        end = uint64(block.timestamp + 1 days);
    }

    function test_presaleCreatesCanonicalLockedV2PoolAndTradesTaxedToken() public {
        ArchAdapterPresale presale = _createPresale();
        assertTrue(launchpad.isLaunch(address(presale)));
        assertEq(launchpad.presaleCount(), 1);

        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 2 ether}();
        presale.finalize();

        ArchToken token = presale.token();
        assertEq(token.TAX_BPS(), 300);
        assertEq(address(token.STOCK()), address(stock));
        address pair = v2Factory.getPair(address(token), address(weth));
        assertEq(presale.pair(), pair);
        assertTrue(locker.isCanonicalPair(pair));
        assertTrue(token.isMarketPair(pair));
        assertTrue(token.isTaxExempt(address(liquidityAdapter)));
        assertTrue(token.wired());

        ArchLiquidityLocker.Lock memory created = locker.getLock(0);
        assertEq(created.token, pair);
        assertEq(created.owner, creator);
        assertGt(created.amount, 0);
        assertEq(IERC20(pair).balanceOf(address(locker)), created.amount);

        vm.prank(alice);
        presale.claim();
        vm.startPrank(alice);
        token.approve(address(swapAdapter), type(uint256).max);
        uint256 wethOut = swapAdapter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
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
        assertGt(token.balanceOf(address(token)), 0);

        weth.transfer(bob, 0.1 ether);
        vm.startPrank(bob);
        weth.approve(address(swapAdapter), type(uint256).max);
        uint256 bought = swapAdapter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(token),
                fee: 0,
                recipient: bob,
                amountIn: 0.1 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertEq(token.balanceOf(bob), bought);

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

    function test_curveGraduatesExactlyIntoPermanentV2Liquidity() public {
        ArchAdapterBondingCurve.TokenConfig memory tokenConfig = ArchAdapterBondingCurve.TokenConfig({
            name: "V2 Curve",
            symbol: "V2C",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterBondingCurve.CurveConfig memory curveConfig =
            ArchAdapterBondingCurve.CurveConfig({curvePct: 80, virtualEth: 1 ether, gradEth: 0.99 ether, poolFee: 0});

        vm.prank(creator);
        ArchAdapterBondingCurve curve =
            ArchAdapterBondingCurve(payable(launchpad.createCurve{value: LISTING_FEE}(tokenConfig, curveConfig)));
        assertTrue(launchpad.isLaunch(address(curve)));

        assertEq(curve.graduationBuyAmount(), 1 ether);

        vm.prank(alice);
        curve.buy{value: 1 ether}(0);

        ArchToken token = curve.token();
        address pair = v2Factory.getPair(address(token), address(weth));
        assertTrue(curve.graduated());
        assertEq(curve.pair(), pair);
        assertTrue(token.wired());
        assertTrue(token.isMarketPair(pair));
        assertGt(IERC20(pair).balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(curve)), 0);
    }

    function test_factoryCreatesPermanentCanonicalV2Liquidity() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Factory",
            symbol: "V2F",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory liquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: true, lpPct: 50, poolFee: 0, burnLp: true, lockDuration: 0
        });

        vm.prank(creator);
        address payable tokenAddress =
            payable(tokenFactory.createToken{value: FACTORY_FEE + 2 ether}(tokenParams, liquidity));
        address pair = v2Factory.getPair(tokenAddress, address(weth));
        assertTrue(ArchToken(tokenAddress).isMarketPair(pair));
        assertTrue(ArchToken(tokenAddress).isTaxExempt(address(liquidityAdapter)));
        assertGt(IERC20(pair).balanceOf(DEAD), 0);
        assertEq(ArchToken(tokenAddress).balanceOf(creator), SUPPLY / 2);
    }

    function test_userAddsExactRatioLiquidityWithoutTradeTaxAndReceivesLock() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Add Liquidity",
            symbol: "V2AL",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory liquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: true, lpPct: 50, poolFee: 0, burnLp: true, lockDuration: 0
        });

        vm.prank(creator);
        ArchToken token =
            ArchToken(payable(tokenFactory.createToken{value: FACTORY_FEE + 2 ether}(tokenParams, liquidity)));
        address pair = v2Factory.getPair(address(token), address(weth));
        uint256 tokenAmount = 50_000e18;
        uint256 wethAmount = 0.2 ether;
        uint256 taxBefore = token.balanceOf(address(token));

        vm.startPrank(creator);
        token.approve(address(provisioner), tokenAmount);
        IArchLaunchLiquidityAdapter.SeedResult memory added =
            provisioner.addLiquidity{value: wethAmount}(token, tokenAmount, pair, 180 days, false);
        vm.stopPrank();

        assertEq(added.market, pair);
        assertEq(added.tokenUsed, tokenAmount);
        assertEq(added.wethUsed, wethAmount);
        assertEq(token.balanceOf(address(token)), taxBefore, "liquidity transfer must not accrue trade tax");
        assertEq(token.allowance(address(provisioner), address(liquidityAdapter)), 0);
        assertEq(token.balanceOf(address(provisioner)), 0);
        assertEq(weth.balanceOf(address(provisioner)), 0);

        ArchLiquidityLocker.Lock memory created = locker.getLock(added.lockId);
        assertEq(created.token, pair);
        assertEq(created.owner, creator);
        assertEq(created.amount, added.positionIdOrAmount);
        assertEq(created.unlockTime, uint64(block.timestamp) + 180 days);
    }

    function test_userProvisioningRejectsUnregisteredMarketBeforeMovingFunds() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Guarded Liquidity",
            symbol: "V2GL",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory liquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: true, lpPct: 50, poolFee: 0, burnLp: true, lockDuration: 0
        });

        vm.prank(creator);
        ArchToken token =
            ArchToken(payable(tokenFactory.createToken{value: FACTORY_FEE + 2 ether}(tokenParams, liquidity)));
        address wrongMarket = address(stock);
        uint256 creatorBefore = token.balanceOf(creator);

        vm.startPrank(creator);
        token.approve(address(provisioner), 1e18);
        vm.expectRevert("provisioner: unregistered market");
        provisioner.addLiquidity{value: 1 ether}(token, 1e18, wrongMarket, 180 days, false);
        vm.stopPrank();
        assertEq(token.balanceOf(creator), creatorBefore);
    }

    function test_deferredFirstMarketRejectsNonzeroExpectationBeforeMovingFunds() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Deferred Guard",
            symbol: "V2DG",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory noLiquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: false, lpPct: 0, poolFee: 0, burnLp: false, lockDuration: 0
        });
        vm.prank(creator);
        ArchToken token = ArchToken(payable(tokenFactory.createToken{value: FACTORY_FEE}(tokenParams, noLiquidity)));
        uint256 creatorBefore = token.balanceOf(creator);

        vm.startPrank(creator);
        token.approve(address(provisioner), 100_000e18);
        vm.expectRevert("provisioner: first market expectation");
        provisioner.addLiquidity{value: 1 ether}(token, 100_000e18, address(stock), 180 days, false);
        vm.stopPrank();

        assertEq(token.balanceOf(creator), creatorBefore);
        assertEq(token.marketPairCount(), 0);
        assertEq(v2Factory.getPair(address(token), address(weth)), address(0));
    }

    function test_additionalLiquidityRejectsUnsafeLockModesAtomically() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Lock Guard",
            symbol: "V2LG",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory liquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: true, lpPct: 50, poolFee: 0, burnLp: true, lockDuration: 0
        });
        vm.prank(creator);
        ArchToken token =
            ArchToken(payable(tokenFactory.createToken{value: FACTORY_FEE + 2 ether}(tokenParams, liquidity)));
        address pair = v2Factory.getPair(address(token), address(weth));
        uint256 tokenBefore = token.balanceOf(creator);
        uint256 ethBefore = creator.balance;

        vm.startPrank(creator);
        token.approve(address(provisioner), 150_000e18);
        vm.expectRevert("provisioner: zero duration");
        provisioner.addLiquidity{value: 0.2 ether}(token, 50_000e18, pair, 0, false);
        vm.expectRevert("v2 adapter: lock too short");
        provisioner.addLiquidity{value: 0.2 ether}(token, 50_000e18, pair, 29 days, false);
        vm.expectRevert("provisioner: permanent duration");
        provisioner.addLiquidity{value: 0.2 ether}(token, 50_000e18, pair, 1, true);
        vm.stopPrank();

        assertEq(token.balanceOf(creator), tokenBefore);
        assertEq(creator.balance, ethBefore);
        assertEq(token.balanceOf(address(provisioner)), 0);
        assertEq(weth.balanceOf(address(provisioner)), 0);
    }

    function test_userAdditionalLiquidityCanOnlyUseExactPoolRatio() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Ratio Guard",
            symbol: "V2RG",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory liquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: true, lpPct: 50, poolFee: 0, burnLp: true, lockDuration: 0
        });

        vm.prank(creator);
        ArchToken token =
            ArchToken(payable(tokenFactory.createToken{value: FACTORY_FEE + 2 ether}(tokenParams, liquidity)));
        address pair = v2Factory.getPair(address(token), address(weth));
        uint256 creatorTokenBefore = token.balanceOf(creator);
        uint256 creatorEthBefore = creator.balance;

        vm.startPrank(creator);
        token.approve(address(provisioner), 50_000e18);
        vm.expectRevert("UniswapV2Router: INSUFFICIENT_B_AMOUNT");
        provisioner.addLiquidity{value: 1 ether}(token, 50_000e18, pair, 180 days, false);
        vm.stopPrank();

        assertEq(token.balanceOf(creator), creatorTokenBefore);
        assertEq(creator.balance, creatorEthBefore);
        assertEq(token.balanceOf(address(provisioner)), 0);
        assertEq(weth.balanceOf(address(provisioner)), 0);
    }

    function test_userCanMakeAdditionalLiquidityPermanent() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Permanent Add",
            symbol: "V2PA",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory liquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: true, lpPct: 50, poolFee: 0, burnLp: true, lockDuration: 0
        });

        vm.prank(creator);
        ArchToken token =
            ArchToken(payable(tokenFactory.createToken{value: FACTORY_FEE + 2 ether}(tokenParams, liquidity)));
        address pair = v2Factory.getPair(address(token), address(weth));
        uint256 burnedBefore = IERC20(pair).balanceOf(DEAD);

        vm.startPrank(creator);
        token.approve(address(provisioner), 50_000e18);
        IArchLaunchLiquidityAdapter.SeedResult memory added =
            provisioner.addLiquidity{value: 0.2 ether}(token, 50_000e18, pair, 0, true);
        vm.stopPrank();

        assertEq(added.lockId, type(uint256).max);
        assertEq(IERC20(pair).balanceOf(DEAD) - burnedBefore, added.positionIdOrAmount);
        assertEq(token.balanceOf(address(token)), 0, "permanent liquidity must not be taxed as a trade");
    }

    function test_userCreatesDeferredFirstV2PairAndLocksLiquidity() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Deferred Pair",
            symbol: "V2DP",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory noLiquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: false, lpPct: 0, poolFee: 0, burnLp: false, lockDuration: 0
        });

        vm.prank(creator);
        ArchToken token = ArchToken(payable(tokenFactory.createToken{value: FACTORY_FEE}(tokenParams, noLiquidity)));
        assertEq(token.marketPairCount(), 0);
        assertEq(v2Factory.getPair(address(token), address(weth)), address(0));
        assertEq(token.liquidityProvisioner(), address(provisioner));

        vm.startPrank(creator);
        token.approve(address(provisioner), 100_000e18);
        IArchLaunchLiquidityAdapter.SeedResult memory added =
            provisioner.addLiquidity{value: 1 ether}(token, 100_000e18, address(0), 180 days, false);
        vm.stopPrank();

        address pair = v2Factory.getPair(address(token), address(weth));
        assertEq(added.market, pair);
        assertTrue(token.isMarketPair(pair));
        assertEq(token.marketPairCount(), 1);
        ArchLiquidityLocker.Lock memory created = locker.getLock(added.lockId);
        assertEq(created.owner, creator);
        assertEq(created.token, pair);
        assertEq(IERC20(pair).balanceOf(address(locker)), added.positionIdOrAmount);
    }

    function test_liquidityProvisionerBindingIsImmutableAfterLaunchersFreeze() public {
        assertEq(liquidityAdapter.liquidityProvisioner(), address(provisioner));

        vm.expectRevert("v2 adapter: launchers bound");
        liquidityAdapter.bindLiquidityProvisioner(address(stock));
    }

    function testFuzz_userExactRatioAdditionConservesFundsAndCreatesNonzeroLock(uint96 rawWethAmount) public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "V2 Fuzz Liquidity",
            symbol: "V2FL",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory liquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: true, lpPct: 50, poolFee: 0, burnLp: true, lockDuration: 0
        });
        vm.prank(creator);
        ArchToken token =
            ArchToken(payable(tokenFactory.createToken{value: FACTORY_FEE + 2 ether}(tokenParams, liquidity)));
        address pair = v2Factory.getPair(address(token), address(weth));
        uint256 wethAmount = bound(uint256(rawWethAmount), 1e12, 1 ether);
        uint256 tokenAmount = wethAmount * 250_000;
        uint256 creatorTokenBefore = token.balanceOf(creator);
        uint256 creatorEthBefore = creator.balance;
        uint256 taxBefore = token.balanceOf(address(token));

        vm.startPrank(creator);
        token.approve(address(provisioner), tokenAmount);
        IArchLaunchLiquidityAdapter.SeedResult memory added =
            provisioner.addLiquidity{value: wethAmount}(token, tokenAmount, pair, 180 days, false);
        vm.stopPrank();

        assertEq(added.tokenUsed, tokenAmount);
        assertEq(added.wethUsed, wethAmount);
        assertGt(added.positionIdOrAmount, 0);
        assertEq(token.balanceOf(creator), creatorTokenBefore - tokenAmount);
        assertEq(creator.balance, creatorEthBefore - wethAmount);
        assertEq(token.balanceOf(address(token)), taxBefore);
        assertEq(token.balanceOf(address(provisioner)), 0);
        assertEq(weth.balanceOf(address(provisioner)), 0);
        ArchLiquidityLocker.Lock memory created = locker.getLock(added.lockId);
        assertEq(created.owner, creator);
        assertEq(created.amount, added.positionIdOrAmount);
    }

    function _createPresale() private returns (ArchAdapterPresale) {
        ArchAdapterPresale.TokenConfig memory tokenConfig = ArchAdapterPresale.TokenConfig({
            name: "V2 Presale",
            symbol: "V2P",
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
            poolFee: 0,
            lpLockDuration: 180 days,
            teamCliff: end + 30 days,
            teamEnd: end + 365 days
        });
        vm.prank(creator);
        return ArchAdapterPresale(payable(launchpad.createPresale{value: LISTING_FEE}(tokenConfig, saleConfig)));
    }
}
