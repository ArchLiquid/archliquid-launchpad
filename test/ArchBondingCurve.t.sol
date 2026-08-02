// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchLaunchpad} from "../src/ArchLaunchpad.sol";
import {ArchBondingCurve} from "../src/ArchBondingCurve.sol";
import {ArchPresaleDeployer} from "../src/ArchPresaleDeployer.sol";
import {ArchCurveDeployer} from "../src/ArchCurveDeployer.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {MockERC20, MockNFPM, MockV3Router, MockWETH} from "./mocks/Mocks.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

contract ArchBondingCurveTest is Test {
    uint256 constant LISTING_FEE = 0.1 ether;
    uint256 constant SUPPLY = 1_000_000e18;
    uint24 constant FEE_TIER = 3000;

    ArchTreasury treasury;
    ArchV3PositionLocker locker;
    ArchStockRegistry registry;
    MockERC20 stock;
    MockNFPM nfpm;
    MockV3Router router;
    MockWETH weth;
    ArchLaunchpad launchpad;

    address keeper = makeAddr("keeper");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        treasury = new ArchTreasury(address(this));
        locker = new ArchV3PositionLocker(0.02 ether, payable(address(treasury)), address(this));
        registry = new ArchStockRegistry(address(this));
        stock = new MockERC20("NVDAx", "NVDAx");
        registry.setApproved(address(stock), true);
        nfpm = new MockNFPM();
        router = new MockV3Router();
        weth = new MockWETH();
        registry.setStockSwapExecutor(address(router));

        ArchPresaleDeployer pd = new ArchPresaleDeployer();
        ArchCurveDeployer cd = new ArchCurveDeployer();
        launchpad = new ArchLaunchpad(
            LISTING_FEE,
            payable(address(treasury)),
            locker,
            INonfungiblePositionManager(address(nfpm)),
            ISwapRouter(address(router)),
            IWETH9(address(weth)),
            FEE_TIER,
            keeper,
            registry,
            pd,
            cd
        );
        pd.setLaunchpad(address(launchpad));
        cd.setLaunchpad(address(launchpad));

        vm.deal(creator, 10 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _tokenCfg() internal view returns (ArchBondingCurve.TokenConfig memory) {
        return ArchBondingCurve.TokenConfig({
            name: "Pixel",
            symbol: "PXL",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
    }

    function _curveCfg() internal pure returns (ArchBondingCurve.CurveConfig memory) {
        return ArchBondingCurve.CurveConfig({curvePct: 80, virtualEth: 2 ether, gradEth: 10 ether, poolFee: FEE_TIER});
    }

    function _create() internal returns (ArchBondingCurve) {
        vm.prank(creator);
        address c = launchpad.createCurve{value: LISTING_FEE}(_tokenCfg(), _curveCfg());
        return ArchBondingCurve(c);
    }

    function test_create_takesFeeAndHoldsSupply() public {
        ArchBondingCurve curve = _create();
        assertEq(address(treasury).balance, LISTING_FEE);
        assertEq(launchpad.curveCount(), 1);
        ArchToken token = curve.token();
        assertEq(token.balanceOf(address(curve)), SUPPLY);
        assertEq(curve.CURVE_SUPPLY(), 800_000e18);
        assertEq(curve.LP_SUPPLY(), 200_000e18);
    }

    function test_create_unapprovedStockReverts() public {
        MockERC20 fake = new MockERC20("FAKE", "FAKE");
        ArchBondingCurve.TokenConfig memory t = _tokenCfg();
        t.stock = IERC20(address(fake));
        vm.prank(creator);
        vm.expectRevert("registry: stock not approved");
        launchpad.createCurve{value: LISTING_FEE}(t, _curveCfg());
    }

    function test_buy_deliversTokensAndFee() public {
        ArchBondingCurve curve = _create();
        ArchToken token = curve.token();

        (uint256 expOut, uint256 expFee) = curve.quoteBuy(1 ether);
        uint256 tBefore = address(treasury).balance;

        vm.prank(alice);
        curve.buy{value: 1 ether}(expOut);

        assertEq(token.balanceOf(alice), expOut);
        assertEq(address(treasury).balance - tBefore, expFee);
        assertEq(curve.realEthCollected(), 1 ether - expFee);
        // constant product preserved (favoring the curve)
        assertGe(curve.ethReserve() * curve.tokenReserve(), curve.K());
    }

    function test_buy_slippageReverts() public {
        ArchBondingCurve curve = _create();
        (uint256 expOut,) = curve.quoteBuy(1 ether);
        vm.prank(alice);
        vm.expectRevert("curve: slippage");
        curve.buy{value: 1 ether}(expOut + 1);
    }

    function test_buyThenSell_losesFeesNoDrain() public {
        ArchBondingCurve curve = _create();
        ArchToken token = curve.token();

        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        uint256 got = token.balanceOf(alice);

        vm.startPrank(alice);
        token.approve(address(curve), got);
        uint256 balBefore = alice.balance;
        curve.sell(got, 0);
        vm.stopPrank();

        uint256 recovered = alice.balance - balBefore;
        // a round trip must return strictly less than 1 ETH (two 1% fees +
        // rounding), and the curve must never pay out more than was put in
        assertLt(recovered, 1 ether);
        assertGe(curve.ethReserve() * curve.tokenReserve(), curve.K());
    }

    function test_graduation_burnsLpAndActivatesTax() public {
        ArchBondingCurve curve = _create();
        ArchToken token = curve.token();

        // one large buy crosses the graduation threshold
        vm.prank(alice);
        curve.buy{value: 12 ether}(0);

        assertTrue(curve.graduated());
        address pool = curve.pair();
        assertTrue(token.isMarketPair(pool));
        assertTrue(token.wired());
        // the V3 position NFT was minted to the dead address: liquidity permanent
        assertEq(nfpm.ownerOf(1), curve.DEAD());
        // curve emptied its tokens into the pool
        assertEq(token.balanceOf(address(curve)), 0);
        assertGt(token.balanceOf(pool), 0);
        // alice (a curve buyer) now participates in stock dividends
        assertFalse(token.isDividendExempt(alice));
        assertGt(token.dividendTotalSupply(), 0);
    }

    function test_noTradingAfterGraduation() public {
        ArchBondingCurve curve = _create();
        vm.prank(alice);
        curve.buy{value: 12 ether}(0);

        vm.prank(bob);
        vm.expectRevert("curve: graduated");
        curve.buy{value: 1 ether}(0);

        vm.prank(alice);
        vm.expectRevert("curve: graduated");
        curve.sell(1e18, 0);
    }

    function test_curveBuyIsUntaxed() public {
        ArchBondingCurve curve = _create();
        ArchToken token = curve.token();
        (uint256 expOut,) = curve.quoteBuy(1 ether);
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        // buyer receives exactly the quoted amount: no tax skimmed pre-graduation
        assertEq(token.balanceOf(alice), expOut);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function testFuzz_buyNeverDrainsCurve(uint96 ethIn) public {
        vm.assume(ethIn > 1e12 && ethIn < 9 ether); // stay below graduation
        ArchBondingCurve curve = _create();
        vm.deal(alice, ethIn);
        vm.prank(alice);
        curve.buy{value: ethIn}(0);
        // invariant: product never drops below K, tokens out never exceed supply
        assertGe(curve.ethReserve() * curve.tokenReserve(), curve.K());
        assertLe(curve.token().balanceOf(alice), curve.CURVE_SUPPLY());
    }

    /// @dev SECURITY: a griefer can pre-initialize the graduation pool at a
    ///      hostile price for zero liquidity. Graduation must revert rather than
    ///      seed an empty, mispriced pool. The curve stays pre-graduation and
    ///      fully tradeable, so no funds are locked (sellers keep their exit).
    function test_graduation_revertsOnGriefedPool() public {
        ArchBondingCurve curve = _create();
        ArchToken token = curve.token();

        // model the graduation pool pre-initialized at a hostile price
        nfpm.setGriefNext(true);

        // a buy that would cross the graduation threshold reverts
        vm.prank(alice);
        vm.expectRevert("curve: pool pre-initialized");
        curve.buy{value: 12 ether}(0);

        // the curve is still pre-graduation and small trades still work
        assertFalse(curve.graduated());
        vm.prank(bob);
        curve.buy{value: 1 ether}(0);
        assertGt(token.balanceOf(bob), 0);
    }
}
