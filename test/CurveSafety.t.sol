// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {ArchBondingCurve} from "../src/ArchBondingCurve.sol";
import {ArchAdapterBondingCurve} from "../src/ArchAdapterBondingCurve.sol";
import {IArchLaunchLiquidityAdapter} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {MockERC20, MockWETH, MockV3Router} from "./mocks/Mocks.sol";
import {CurveSafetyAdapter, CurveSafetyNFPM} from "./mocks/CurveSafetyMocks.sol";

// Interfaces keep these regression tests compilable against the old source so
// the new lifecycle and deadline behavior can be demonstrated as failing first.
interface ICurveDeadlineCalls {
    function buyWithDeadline(uint256 minTokensOut, uint256 deadline) external payable;
    function sellWithDeadline(uint256 tokensIn, uint256 minEthOut, uint256 deadline) external;
}

interface ICurveCompletion {
    function completeGraduation(uint256 deadline) external payable;
}

interface ICurveInventory {
    function buy(uint256 minimum) external payable;
    function sell(uint256 amount, uint256 minimum) external;
    function quoteSell(uint256 amount) external view returns (uint256, uint256);
    function token() external view returns (ArchToken);
    function graduated() external view returns (bool);
    function realEthCollected() external view returns (uint256);
    function ethReserve() external view returns (uint256);
    function tokenReserve() external view returns (uint256);
    function LP_SUPPLY() external view returns (uint256);
    function GRAD_ETH() external view returns (uint128);
    function K() external view returns (uint256);
    function graduationBuyAmount() external view returns (uint256);
}

abstract contract CurveSafetyFixture is Test {
    MockERC20 internal stock;
    MockWETH internal weth;
    MockV3Router internal router;
    CurveSafetyAdapter internal adapter;
    CurveSafetyNFPM internal nfpm;
    address internal alice = makeAddr("curve-safety-alice");
    address payable internal treasury = payable(makeAddr("curve-safety-treasury"));
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event GraduationCompleted(address indexed payer, uint256 ethIn, uint256 fee, uint256 tokensOut);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        vm.deal(alice, 1_000 ether);
        stock = new MockERC20("Fixture stock", "FST");
        weth = new MockWETH();
        router = new MockV3Router();
        adapter = new CurveSafetyAdapter(address(weth));
        nfpm = new CurveSafetyNFPM(address(weth));
    }

    function _v4(uint256 supply, uint16 pct, uint128 virtualEth, uint128 gradEth)
        internal
        returns (ArchAdapterBondingCurve)
    {
        return new ArchAdapterBondingCurve(
            alice,
            ArchAdapterBondingCurve.Infra(
                treasury,
                IArchLaunchLiquidityAdapter(address(adapter)),
                ISwapRouter(address(router)),
                IWETH9(address(weth)),
                3000,
                3000,
                IArchStockSwapExecutor(address(0x3333)),
                address(0x4444)
            ),
            ArchAdapterBondingCurve.TokenConfig("Fixture curve", "FC", supply, 300, IERC20(address(stock)), 0),
            ArchAdapterBondingCurve.CurveConfig(pct, virtualEth, gradEth, 3000)
        );
    }

    function _v3() internal returns (ArchBondingCurve) {
        return _v3Configured(1_000_000 ether, 80, 2 ether, 10 ether);
    }

    function _v3Configured(uint256 supply, uint16 pct, uint128 virtualEth, uint128 gradEth)
        internal
        returns (ArchBondingCurve)
    {
        return new ArchBondingCurve(
            alice,
            ArchBondingCurve.Infra(
                treasury,
                INonfungiblePositionManager(address(nfpm)),
                ISwapRouter(address(router)),
                IWETH9(address(weth)),
                3000,
                IArchStockSwapExecutor(address(0x3333)),
                address(0x4444)
            ),
            ArchBondingCurve.TokenConfig("Fixture V3 curve", "FV3", supply, 300, IERC20(address(stock)), 0),
            ArchBondingCurve.CurveConfig(pct, virtualEth, gradEth, 3000)
        );
    }

    function _gross(uint256 net) internal pure returns (uint256) {
        return net + net / 99;
    }
}

contract CurveSafetyTest is CurveSafetyFixture {
    function test_terminalRoundingPlateauKeepsOrdinaryBuyStrictButCanExplicitlyGraduate() public {
        ArchAdapterBondingCurve curve = _v4(1 ether, 80, 2 ether, 10 ether);
        vm.prank(alice);
        curve.buy{value: _gross(10 ether - 1)}(0);
        assertEq(curve.realEthCollected(), 10 ether - 1);
        assertEq(curve.tokenReserve(), Math.ceilDiv(curve.K(), 12 ether));
        assertEq(curve.graduationBuyAmount(), 1);
        (uint256 tokensOut,) = curve.quoteBuy(1);
        assertEq(tokensOut, 0);
        vm.expectRevert("adapter curve: slippage");
        vm.prank(alice);
        curve.buy{value: 1}(0);

        vm.expectEmit(true, false, false, true, address(curve));
        emit GraduationCompleted(alice, 1, 0, 0);
        vm.prank(alice);
        ICurveCompletion(address(curve)).completeGraduation{value: 1}(block.timestamp);
        assertTrue(curve.graduated());
        assertEq(curve.realEthCollected(), 10 ether);
        assertEq(adapter.ownerOf(1), DEAD);
        assertEq(curve.token().balanceOf(address(curve)), 0);
    }

    function test_completionRejectsExpiredWrongValueAndProductiveOrdinaryBuy() public {
        ArchAdapterBondingCurve curve = _v4(1 ether, 80, 2 ether, 10 ether);
        vm.expectRevert("adapter curve: completion not needed");
        vm.prank(alice);
        ICurveCompletion(address(curve)).completeGraduation{value: _gross(10 ether)}(block.timestamp);
        vm.prank(alice);
        curve.buy{value: _gross(10 ether - 1)}(0);
        uint256 curveBalance = address(curve).balance;
        uint256 treasuryBalance = treasury.balance;
        vm.expectRevert("adapter curve: expired");
        vm.prank(alice);
        ICurveCompletion(address(curve)).completeGraduation{value: 1}(block.timestamp - 1);
        vm.expectRevert("adapter curve: wrong completion value");
        vm.prank(alice);
        ICurveCompletion(address(curve)).completeGraduation{value: 2}(block.timestamp);
        assertEq(address(curve).balance, curveBalance);
        assertEq(treasury.balance, treasuryBalance);
        assertEq(curve.realEthCollected(), 10 ether - 1);
        assertFalse(curve.graduated());
    }

    function test_completionFailureRollsBackFundingFeesAndPermanentCustody() public {
        ArchAdapterBondingCurve curve = _v4(1 ether, 80, 4 ether, 20 ether);
        vm.prank(alice);
        curve.buy{value: _gross(20 ether - 100)}(0);
        assertEq(curve.tokenReserve(), Math.ceilDiv(curve.K(), 24 ether));
        uint256 amount = curve.graduationBuyAmount();
        uint256 userBalance = alice.balance;
        uint256 curveBalance = address(curve).balance;
        uint256 treasuryBalance = treasury.balance;
        adapter.setFailure(true);
        vm.expectRevert("fixture adapter: failed seed");
        vm.prank(alice);
        ICurveCompletion(address(curve)).completeGraduation{value: amount}(block.timestamp);
        assertEq(alice.balance, userBalance);
        assertEq(address(curve).balance, curveBalance);
        assertEq(treasury.balance, treasuryBalance);
        assertEq(curve.realEthCollected(), 20 ether - 100);
        assertEq(weth.balanceOf(address(curve)), 0);
        assertFalse(curve.graduated());
    }

    function test_donationsCannotPoisonThePreviouslyValidatedUint128GraduationSeed() public {
        uint256 maximum = type(uint128).max;
        ArchAdapterBondingCurve curve = _v4(2 * maximum, 99, 1 ether, 9 ether);
        uint256 expectedSeed = Math.ceilDiv(curve.K(), 10 ether) + curve.LP_SUPPLY();
        assertLe(expectedSeed, maximum);
        vm.prank(alice);
        curve.buy{value: _gross(9 ether - 1)}(0);
        uint256 donated = maximum - expectedSeed + 1;
        ArchToken launched = curve.token();
        assertGe(launched.balanceOf(alice), donated);
        vm.prank(alice);
        launched.transfer(address(curve), donated);
        vm.prank(alice);
        curve.buy{value: 1}(0);
        assertTrue(curve.graduated());
        assertEq(adapter.tokenSeeded(), expectedSeed);
        assertEq(curve.token().balanceOf(DEAD), donated);
        assertEq(curve.token().balanceOf(address(curve)), 0);
    }

    function testFuzz_donationsDoNotChangeV4SeedAmounts(uint256 donationSeed) public {
        ArchAdapterBondingCurve curve = _v4(1_000_000 ether, 80, 1 ether, 9 ether);
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        ArchToken launched = curve.token();
        uint256 donation = bound(donationSeed, 0, launched.balanceOf(alice));
        vm.prank(alice);
        launched.transfer(address(curve), donation);
        uint256 expectedTokens = Math.ceilDiv(curve.K(), 10 ether) + curve.LP_SUPPLY();
        uint256 graduationValue = curve.graduationBuyAmount();
        vm.prank(alice);
        curve.buy{value: graduationValue}(0);
        assertEq(adapter.tokenSeeded(), expectedTokens);
        assertEq(adapter.wethSeeded(), 9 ether);
        assertEq(curve.token().balanceOf(DEAD), donation);
        assertEq(curve.token().allowance(address(curve), address(adapter)), 0);
        assertEq(weth.allowance(address(curve), address(adapter)), 0);
    }

    function test_deadlineEntryPointsRejectStaleTradesBeforeCustodyChanges() public {
        ArchBondingCurve v3 = _v3();
        ArchAdapterBondingCurve v4 = _v4(1_000_000 ether, 80, 2 ether, 10 ether);
        for (uint256 i; i < 2; i++) {
            address curve = i == 0 ? address(v3) : address(v4);
            uint256 treasuryBefore = treasury.balance;
            vm.expectRevert(i == 0 ? bytes("curve: expired") : bytes("adapter curve: expired"));
            vm.prank(alice);
            ICurveDeadlineCalls(curve).buyWithDeadline{value: 1 ether}(0, block.timestamp - 1);
            vm.expectRevert(i == 0 ? bytes("curve: expired") : bytes("adapter curve: expired"));
            vm.prank(alice);
            ICurveDeadlineCalls(curve).sellWithDeadline(1 ether, 0, block.timestamp - 1);
            assertEq(address(curve).balance, 0);
            assertEq(treasury.balance, treasuryBefore);
        }
    }

    function test_deadlineBoundaryUsesTheSameBuyAndSellArithmeticAsLegacyEntryPoints() public {
        ArchBondingCurve v3 = _v3();
        ArchAdapterBondingCurve v4 = _v4(1_000_000 ether, 80, 2 ether, 10 ether);
        for (uint256 i; i < 2; i++) {
            address curve = i == 0 ? address(v3) : address(v4);
            ArchToken launched = i == 0 ? v3.token() : v4.token();
            (uint256 output,) = i == 0 ? v3.quoteBuy(1 ether) : v4.quoteBuy(1 ether);
            vm.prank(alice);
            ICurveDeadlineCalls(curve).buyWithDeadline{value: 1 ether}(output, block.timestamp);
            assertEq(launched.balanceOf(alice), output);
            (uint256 ethOut,) = i == 0 ? v3.quoteSell(output) : v4.quoteSell(output);
            vm.prank(alice);
            launched.approve(curve, output);
            uint256 balanceBefore = alice.balance;
            vm.prank(alice);
            ICurveDeadlineCalls(curve).sellWithDeadline(output, ethOut, block.timestamp);
            assertEq(alice.balance - balanceBefore, ethOut);
            assertEq(launched.balanceOf(alice), 0);
        }
    }

    function test_v3AccountsForDonationsActualMintConsumptionDustAndClearedApprovals() public {
        ArchBondingCurve curve = _v3();
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        uint256 donation = 100 ether;
        ArchToken launched = curve.token();
        vm.prank(alice);
        launched.transfer(address(curve), donation);
        nfpm.setDust(7, 11);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        curve.buy{value: 12 ether}(0);
        assertTrue(curve.graduated());
        assertEq(curve.token().balanceOf(DEAD), donation + 7);
        assertEq(curve.token().balanceOf(address(curve)), 0);
        assertEq(weth.balanceOf(address(curve)), 0);
        assertEq(treasury.balance - treasuryBefore, 0.12 ether + 11);
        assertEq(curve.token().allowance(address(curve), address(nfpm)), 0);
        assertEq(weth.allowance(address(curve), address(nfpm)), 0);
        assertEq(nfpm.ownerOf(1), DEAD);
    }

    function test_completionCanRequireSubstantialExplicitFundingForCoarseTokenUnits() public {
        ArchAdapterBondingCurve curve = _v4(20, 80, 10 ether, 90 ether);
        vm.prank(alice);
        curve.buy{value: _gross(70 ether)}(0);
        assertEq(curve.tokenReserve(), 2);
        uint256 gross = curve.graduationBuyAmount();
        assertEq(gross, _gross(20 ether));
        (uint256 tokensOut,) = curve.quoteBuy(gross);
        assertEq(tokensOut, 0);
        uint256 userTokens = curve.token().balanceOf(alice);
        vm.prank(alice);
        ICurveCompletion(address(curve)).completeGraduation{value: gross}(block.timestamp);
        assertTrue(curve.graduated());
        assertEq(curve.token().balanceOf(alice), userTokens);
        assertEq(adapter.wethSeeded(), 90 ether);
    }

    function test_completionRejectsFundedCurveWhereOrdinaryTargetBuyIsProductive() public {
        ArchAdapterBondingCurve curve = _v4(1_000_000 ether, 80, 2 ether, 10 ether);
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        uint256 gross = curve.graduationBuyAmount();
        (uint256 tokensOut,) = curve.quoteBuy(gross);
        assertGt(tokensOut, 0);
        vm.expectRevert("adapter curve: completion not needed");
        vm.prank(alice);
        ICurveCompletion(address(curve)).completeGraduation{value: gross}(block.timestamp);
        assertFalse(curve.graduated());
    }

    function test_v3RejectsSingleUnitCurveThatCanNeverProduceOutput() public {
        vm.expectRevert("curve: no productive range");
        _v3Configured(2, 80, 2 ether, 10 ether);
    }

    function test_v3PreservesProductiveOvershootEvenWhenConfiguredTargetAloneRoundsToZero() public {
        ArchBondingCurve curve = _v3Configured(4, 50, 10 ether, 1);
        (uint256 targetOutput,) = curve.quoteBuy(1);
        assertEq(targetOutput, 0);
        uint256 gross = _gross(10 ether);
        (uint256 overshootOutput,) = curve.quoteBuy(gross);
        assertEq(overshootOutput, 1);
        vm.prank(alice);
        curve.buy{value: gross}(overshootOutput);
        assertTrue(curve.graduated());
        assertEq(curve.realEthCollected(), 10 ether);
        assertEq(curve.token().balanceOf(alice), overshootOutput);
        assertEq(nfpm.ownerOf(1), DEAD);
    }

    function test_degenerateV4ConfigurationsRejectNoProductiveTokenRange() public {
        vm.expectRevert("adapter curve: no productive range");
        _v4(2, 80, 2 ether, 10 ether);
    }

    function testFuzz_feeInverseReachesTheExactNetTarget(uint256 remainingSeed) public pure {
        uint256 remaining = bound(remainingSeed, 1, 100 ether);
        uint256 gross = _gross(remaining);
        assertEq(gross - gross / 100, remaining);
    }

    function testFuzz_explicitCompletionHandlesProductivePlateaus(
        uint64 supplySeed,
        uint96 virtualSeed,
        uint8 factorSeed
    ) public {
        uint256 supply = bound(uint256(supplySeed), 20, 10_000);
        uint128 virtualEth = uint128(bound(uint256(virtualSeed), 1 ether, 10 ether));
        uint128 gradEth = uint128(uint256(virtualEth) * bound(uint256(factorSeed), 1, 9));
        ArchAdapterBondingCurve curve = _v4(supply, 80, virtualEth, gradEth);
        uint256 terminalReserve = Math.ceilDiv(curve.K(), uint256(virtualEth) + gradEth);
        uint256 netToPlateau = Math.ceilDiv(curve.K(), terminalReserve) - virtualEth;
        assertGt(netToPlateau, 0);
        assertLe(netToPlateau, gradEth);
        vm.prank(alice);
        curve.buy{value: _gross(netToPlateau)}(0);
        uint256 remaining = uint256(gradEth) - netToPlateau;
        if (remaining == 0) {
            assertTrue(curve.graduated());
            return;
        }
        uint256 gross = curve.graduationBuyAmount();
        (uint256 quoted, uint256 fee) = curve.quoteBuy(gross);
        assertEq(quoted, 0);
        assertEq(gross - fee, remaining);
        uint256 userTokens = curve.token().balanceOf(alice);
        vm.expectRevert("adapter curve: slippage");
        vm.prank(alice);
        curve.buy{value: gross}(0);
        vm.prank(alice);
        ICurveCompletion(address(curve)).completeGraduation{value: gross}(block.timestamp);
        assertTrue(curve.graduated());
        assertEq(curve.realEthCollected(), gradEth);
        assertEq(curve.token().balanceOf(alice), userTokens);
        assertEq(adapter.ownerOf(1), DEAD);
    }

    function test_v3RejectsMissingOrZeroLiquidityPermanentPositionsAtomically() public {
        for (uint8 mode = 1; mode <= 4; mode++) {
            ArchBondingCurve curve = _v3();
            nfpm.setInvalidResult(mode);
            bytes memory reason = mode <= 2
                ? bytes("curve: empty seed")
                : mode == 3 ? bytes("curve: seed overflow") : bytes("curve: invalid permanent custody");
            vm.expectRevert(reason);
            vm.prank(alice);
            curve.buy{value: 12 ether}(0);
            assertFalse(curve.graduated());
            assertEq(curve.realEthCollected(), 0);
            assertEq(curve.token().balanceOf(alice), 0);
        }
    }

    function test_v4RejectsIncorrectReportedConsumptionAtomically() public {
        ArchAdapterBondingCurve curve = _v4(1_000_000 ether, 80, 2 ether, 10 ether);
        adapter.setDust(2, 2);
        adapter.setLyingConsumption(true);
        uint256 treasuryBefore = treasury.balance;
        vm.expectRevert("adapter curve: seed accounting mismatch");
        vm.prank(alice);
        curve.buy{value: _gross(10 ether)}(0);
        assertFalse(curve.graduated());
        assertEq(curve.realEthCollected(), 0);
        assertEq(treasury.balance, treasuryBefore);
        assertEq(curve.token().balanceOf(alice), 0);
        assertEq(weth.balanceOf(address(curve)), 0);
    }

    function test_v4PartialSeedBurnsTokenDustReturnsOnlyTrackedWethDustAndClearsAllowances() public {
        ArchAdapterBondingCurve curve = _v4(1_000_000 ether, 80, 2 ether, 10 ether);
        adapter.setDust(7, 11);
        weth.mint(address(curve), 37);
        uint256 treasuryBefore = treasury.balance;
        uint256 gross = _gross(10 ether);
        vm.prank(alice);
        curve.buy{value: gross}(0);
        assertTrue(curve.graduated());
        assertEq(curve.token().balanceOf(address(curve)), 0);
        assertEq(curve.token().balanceOf(DEAD), 7);
        assertEq(weth.balanceOf(address(curve)), 37);
        assertEq(treasury.balance - treasuryBefore, gross / 100 + 11);
        assertEq(curve.token().allowance(address(curve), address(adapter)), 0);
        assertEq(weth.allowance(address(curve), address(adapter)), 0);
    }

    function test_v3RejectsUnsolicitedEthAndPreservesPreviouslyDonatedWeth() public {
        ArchBondingCurve curve = _v3();
        vm.prank(alice);
        (bool accepted,) = address(curve).call{value: 1}("");
        assertFalse(accepted);
        weth.mint(address(curve), 37);
        nfpm.setDust(7, 11);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        curve.buy{value: 12 ether}(0);
        assertTrue(curve.graduated());
        assertEq(weth.balanceOf(address(curve)), 37);
        assertEq(treasury.balance - treasuryBefore, 0.12 ether + 11);
    }

    function test_v3RejectsIncorrectReportedConsumptionAtomically() public {
        ArchBondingCurve curve = _v3();
        nfpm.setDust(2, 2);
        nfpm.setLyingConsumption(true);
        uint256 treasuryBefore = treasury.balance;
        vm.expectRevert("curve: seed accounting mismatch");
        vm.prank(alice);
        curve.buy{value: 12 ether}(0);
        assertFalse(curve.graduated());
        assertEq(curve.realEthCollected(), 0);
        assertEq(treasury.balance, treasuryBefore);
        assertEq(curve.token().balanceOf(alice), 0);
        assertEq(weth.balanceOf(address(curve)), 0);
    }
}

/// @dev Bounded multi-step transitions through both real curve implementations.
///      Catching rejected operations lets Foundry explore dust and stale-state
///      transitions while invariants check every committed transition.
contract CurveSafetyHandler is Test {
    ICurveInventory[2] private curves;

    constructor(address v3, address v4) {
        curves = [ICurveInventory(v3), ICurveInventory(v4)];
    }

    receive() external payable {}

    function buy(uint8 family, uint96 input) external {
        uint256 selected = uint256(family) % 2;
        ICurveInventory curve = curves[selected];
        if (curve.graduated()) return;
        uint256 maximum = selected == 0 ? 2 ether : uint256(curve.GRAD_ETH()) - curve.realEthCollected();
        if (selected == 1) maximum += maximum / 99;
        if (maximum == 0 || address(this).balance < maximum) return;
        uint256 gross = bound(uint256(input), 1, maximum);
        try curve.buy{value: gross}(0) {} catch {}
    }

    function sell(uint8 family, uint256 input) external {
        ICurveInventory curve = curves[uint256(family) % 2];
        if (curve.graduated()) return;
        ArchToken launched = curve.token();
        uint256 balance = launched.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(input, 1, balance);
        (uint256 quoted,) = curve.quoteSell(amount);
        launched.approve(address(curve), amount);
        try curve.sell(amount, quoted) {} catch {}
    }

    function donate(uint8 family, uint256 input) external {
        ICurveInventory curve = curves[uint256(family) % 2];
        if (curve.graduated()) return;
        ArchToken launched = curve.token();
        uint256 balance = launched.balanceOf(address(this));
        if (balance == 0) return;
        launched.transfer(address(curve), bound(input, 0, balance));
    }

    function completeGraduation() external {
        ICurveInventory curve = curves[1];
        if (curve.graduated()) return;
        uint256 gross = curve.graduationBuyAmount();
        if (gross == 0 || gross > address(this).balance) return;
        try ICurveCompletion(address(curve)).completeGraduation{value: gross}(block.timestamp) {} catch {}
    }
}

contract CurveSafetyInvariantTest is CurveSafetyFixture {
    ICurveInventory[2] private curves;

    function setUp() public override {
        super.setUp();
        curves =
            [ICurveInventory(address(_v3())), ICurveInventory(address(_v4(1_000_000 ether, 80, 2 ether, 10 ether)))];
        CurveSafetyHandler handler = new CurveSafetyHandler(address(curves[0]), address(curves[1]));
        vm.deal(address(handler), 500 ether);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = CurveSafetyHandler.buy.selector;
        selectors[1] = CurveSafetyHandler.sell.selector;
        selectors[2] = CurveSafetyHandler.donate.selector;
        selectors[3] = CurveSafetyHandler.completeGraduation.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_accountedReservesRemainSolventAndGraduationClearsCustody() public view {
        for (uint256 i; i < 2; i++) {
            ICurveInventory curve = curves[i];
            ArchToken launched = curve.token();
            address spender = i == 0 ? address(nfpm) : address(adapter);
            if (!curve.graduated()) {
                assertGe(curve.ethReserve() * curve.tokenReserve(), curve.K());
                assertGe(address(curve).balance, curve.realEthCollected());
                assertGe(launched.balanceOf(address(curve)), curve.tokenReserve() + curve.LP_SUPPLY());
                assertEq(curve.ethReserve() - curve.realEthCollected(), 2 ether);
            } else {
                assertTrue(launched.wired());
                assertEq(launched.balanceOf(address(curve)), 0);
                assertEq(weth.balanceOf(address(curve)), 0);
                assertEq(launched.allowance(address(curve), spender), 0);
                assertEq(weth.allowance(address(curve), spender), 0);
                assertEq(i == 0 ? nfpm.ownerOf(1) : adapter.ownerOf(1), DEAD);
            }
        }
    }
}
