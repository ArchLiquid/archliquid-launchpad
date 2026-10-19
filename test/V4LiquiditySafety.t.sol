// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {IWETH9, ISwapRouter} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {IUniswapV4PositionManager as LockerPositionManager} from "@archliquid/lockers/interfaces/IUniswapV4.sol";
import {ArchV4LaunchLiquidityAdapter} from "../src/ArchV4LaunchLiquidityAdapter.sol";
import {ArchV4UserLiquidityProvisioner} from "../src/ArchV4UserLiquidityProvisioner.sol";
import {IArchLaunchRegistry, IArchLaunchLiquidityAdapter} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {
    IUniswapV4PositionManager,
    IUniswapV4StateView,
    IPermit2AllowanceTransfer,
    PoolKey
} from "../src/interfaces/IUniswapV4.sol";
import {
    V4SafetyWETH,
    V4SafetyPermit2,
    V4SafetyPoolManager,
    V4SafetyStateView,
    V4SafetyPositionManager
} from "./mocks/V4SafetyMocks.sol";

contract V4LiquiditySafetyTest is Test {
    uint256 private constant TOKEN_AMOUNT = 10 ether;
    uint256 private constant WETH_AMOUNT = 2 ether;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    V4SafetyWETH private weth;
    V4SafetyPermit2 private permit2;
    V4SafetyPoolManager private poolManager;
    V4SafetyStateView private stateView;
    V4SafetyPositionManager private positionManager;
    ArchV4PositionLocker private locker;
    ArchV4LaunchLiquidityAdapter private adapter;
    ArchV4UserLiquidityProvisioner private provisioner;
    ArchToken private token;
    address private _expectedMarket;

    receive() external payable {}

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 100 ether);
        weth = new V4SafetyWETH();
        permit2 = new V4SafetyPermit2();
        poolManager = new V4SafetyPoolManager();
        stateView = new V4SafetyStateView(address(poolManager));
        positionManager = new V4SafetyPositionManager(address(poolManager), address(permit2));
        locker = new ArchV4PositionLocker(
            0, payable(address(this)), LockerPositionManager(address(positionManager)), address(this)
        );
        adapter = new ArchV4LaunchLiquidityAdapter(
            IUniswapV4PositionManager(address(positionManager)),
            stateView,
            IPermit2AllowanceTransfer(address(permit2)),
            IERC20(address(weth)),
            locker,
            address(this)
        );
        provisioner = new ArchV4UserLiquidityProvisioner(adapter);
        adapter.bindLiquidityProvisioner(address(provisioner));
        adapter.bindLaunchers(address(this), IArchLaunchRegistry(address(0)));
        locker.setFeeExempt(address(adapter), true);
        token = new ArchToken(
            "V4 Safety",
            "V4S",
            1_000 ether,
            300,
            IERC20(address(weth)),
            ArchToken.DexConfig({
                swapRouter: ISwapRouter(address(this)),
                weth: IWETH9(address(weth)),
                tokenPoolFee: 3000,
                stockPoolFee: 0,
                stockSwapExecutor: IArchStockSwapExecutor(address(this))
            }),
            payable(address(this)),
            address(this),
            0,
            address(this)
        );
        token.setTaxExempt(address(adapter));
        token.setLiquidityProvisioner(address(provisioner));
        token.finalizeWiring();
        token.approve(address(provisioner), type(uint256).max);
    }

    function test_constructorRejectsStateViewForDifferentPoolManager() public {
        V4SafetyPoolManager otherManager = new V4SafetyPoolManager();
        V4SafetyStateView wrongView = new V4SafetyStateView(address(otherManager));
        vm.expectRevert("v4 adapter: state view pool mismatch");
        new ArchV4LaunchLiquidityAdapter(
            IUniswapV4PositionManager(address(positionManager)),
            wrongView,
            IPermit2AllowanceTransfer(address(permit2)),
            IERC20(address(weth)),
            locker,
            address(this)
        );
    }

    function test_constructorRejectsPermit2DifferentFromPositionManager() public {
        V4SafetyPermit2 otherPermit2 = new V4SafetyPermit2();
        vm.expectRevert("v4 adapter: permit2 mismatch");
        new ArchV4LaunchLiquidityAdapter(
            IUniswapV4PositionManager(address(positionManager)),
            stateView,
            IPermit2AllowanceTransfer(address(otherPermit2)),
            IERC20(address(weth)),
            locker,
            address(this)
        );
    }

    function test_mintedPositionCannotSubstituteAnotherPoolKey() public {
        positionManager.setWrongPositionPool(true);
        vm.expectRevert("v4 adapter: position pool mismatch");
        _legacy(true);
    }

    function test_legacySelectorPreservesRefundsAndTimedCustody() public {
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        IArchLaunchLiquidityAdapter.SeedResult memory result = _legacy(false);
        assertEq(result.tokenUsed, TOKEN_AMOUNT * 3 / 4);
        assertEq(result.wethUsed, WETH_AMOUNT * 3 / 4);
        assertEq(token.balanceOf(address(this)), tokenBefore - result.tokenUsed);
        assertEq(address(this).balance, ethBefore - result.wethUsed);
        assertEq(positionManager.ownerOf(result.positionIdOrAmount), address(locker));
        assertEq(locker.getLock(result.lockId).owner, address(this));
        _assertNoResidueOrApprovals();
    }

    function test_limitsDeadlineCheckedBeforeTokenInteraction() public {
        vm.mockCallRevert(
            address(token), abi.encodeWithSelector(token.wired.selector), abi.encode("unexpected token call")
        );
        vm.expectRevert("v4 provisioner: expired");
        _limited(true, block.timestamp - 1, 0, 0, 0);
    }

    function test_limitsRejectImpossibleInputMinimumBeforeTokenInteraction() public {
        vm.mockCallRevert(
            address(token), abi.encodeWithSelector(token.wired.selector), abi.encode("unexpected token call")
        );
        vm.expectRevert("v4 provisioner: excessive minimum");
        _limited(true, block.timestamp, TOKEN_AMOUNT + 1, 0, 0);
    }

    function test_limitsRejectImpossibleWethMinimum() public {
        vm.expectRevert("v4 provisioner: excessive minimum");
        _limited(true, block.timestamp, 0, WETH_AMOUNT + 1, 0);
    }

    function test_limitsExactDeadlineAndInputMinimaAcceptPartialConsumption() public {
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        IArchLaunchLiquidityAdapter.SeedResult memory result =
            _limited(true, block.timestamp, TOKEN_AMOUNT * 3 / 4, WETH_AMOUNT * 3 / 4, 1);
        assertEq(token.balanceOf(address(this)), tokenBefore - result.tokenUsed);
        assertEq(address(this).balance, ethBefore - result.wethUsed);
        assertEq(result.lockId, type(uint256).max);
        assertEq(positionManager.ownerOf(result.positionIdOrAmount), DEAD);
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(result.positionIdOrAmount);
        assertEq(result.poolId, keccak256(abi.encode(key)));
        assertEq(key.currency0, address(token) < address(weth) ? address(token) : address(weth));
        assertEq(key.currency1, address(token) < address(weth) ? address(weth) : address(token));
        assertEq(key.fee, 3000);
        assertEq(key.tickSpacing, 60);
        assertEq(key.hooks, address(0));
        _assertNoResidueOrApprovals();
    }

    function test_limitsRejectActualTokenConsumptionBelowMinimumAtomically() public {
        uint256 balance = token.balanceOf(address(this));
        uint256 ethBalance = address(this).balance;
        vm.expectRevert("v4 provisioner: input minimum");
        _limited(true, block.timestamp, TOKEN_AMOUNT * 3 / 4 + 1, 0, 0);
        assertEq(token.balanceOf(address(this)), balance);
        assertEq(address(this).balance, ethBalance);
        assertEq(token.marketPairCount(), 0);
        assertEq(positionManager.nextTokenId(), 1);
        _assertNoResidueOrApprovals();
    }

    function test_limitsRejectActualWethConsumptionBelowMinimumAtomically() public {
        vm.expectRevert("v4 provisioner: input minimum");
        _limited(true, block.timestamp, 0, WETH_AMOUNT * 3 / 4 + 1, 0);
        assertEq(positionManager.nextTokenId(), 1);
        _assertNoResidueOrApprovals();
    }

    function test_limitsMintedLiquidityBoundaryIsInclusive() public {
        uint256 snapshot = vm.snapshotState();
        IArchLaunchLiquidityAdapter.SeedResult memory probe = _legacy(true);
        uint128 minted = positionManager.getPositionLiquidity(probe.positionIdOrAmount);
        assertTrue(vm.revertToState(snapshot));
        _limited(true, block.timestamp, 0, 0, minted);
    }

    function test_limitsRejectInsufficientMintedLiquidityAtomically() public {
        vm.expectRevert("v4 provisioner: liquidity minimum");
        _limited(true, block.timestamp, 0, 0, type(uint128).max);
        assertEq(positionManager.nextTokenId(), 1);
        _assertNoResidueOrApprovals();
    }

    function test_limitsTimedPositionMatchesProviderAndExecutionUnlockTime() public {
        IArchLaunchLiquidityAdapter.SeedResult memory result = _limited(false, block.timestamp + 1, 0, 0, 1);
        ArchV4PositionLocker.Lock memory lock = locker.getLock(result.lockId);
        assertEq(lock.owner, address(this));
        assertEq(lock.tokenId, result.positionIdOrAmount);
        assertEq(lock.unlockTime, block.timestamp + 30 days);
        assertEq(lock.hooks, address(0));
        assertFalse(lock.withdrawn);
        assertEq(positionManager.ownerOf(result.positionIdOrAmount), address(locker));
        _assertNoResidueOrApprovals();
    }

    function test_existingMarketUsesSameCanonicalPoolAndRetainsRegistry() public {
        IArchLaunchLiquidityAdapter.SeedResult memory first = _legacy(true);
        IArchLaunchLiquidityAdapter.SeedResult memory second = _limited(false, block.timestamp, 0, 0, 1);
        assertEq(first.poolId, second.poolId);
        assertEq(token.marketPairCount(), 1);
        assertTrue(token.isMarketPair(address(poolManager)));
        _assertNoResidueOrApprovals();
    }

    function test_donatedBalancesCannotBeRefundedToNextProvider() public {
        uint256 tokenDonation = 5 ether;
        uint256 wethDonation = 1 ether;
        token.transfer(address(provisioner), tokenDonation);
        token.transfer(address(adapter), tokenDonation);
        weth.deposit{value: 2 * wethDonation}();
        weth.transfer(address(provisioner), wethDonation);
        weth.transfer(address(adapter), wethDonation);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        IArchLaunchLiquidityAdapter.SeedResult memory result = _limited(true, block.timestamp, 0, 0, 1);
        assertEq(token.balanceOf(address(this)), tokenBefore - result.tokenUsed);
        assertEq(address(this).balance, ethBefore - result.wethUsed);
        assertEq(token.balanceOf(address(provisioner)), tokenDonation);
        assertEq(token.balanceOf(address(adapter)), tokenDonation);
        assertEq(weth.balanceOf(address(provisioner)), wethDonation);
        assertEq(weth.balanceOf(address(adapter)), wethDonation);
        assertEq(token.allowance(address(provisioner), address(adapter)), 0);
        assertEq(token.allowance(address(adapter), address(permit2)), 0);
    }

    function test_mintedPositionCannotSubstituteDifferentCurrencies() public {
        positionManager.setWrongPositionPoolKind(2);
        vm.expectRevert("v4 adapter: position pool mismatch");
        _legacy(true);
    }

    function test_mintedPositionCannotSubstituteHookOrSpacing() public {
        positionManager.setWrongPositionPoolKind(3);
        vm.expectRevert("v4 adapter: position pool mismatch");
        _legacy(true);
    }

    function test_mintedPositionCannotSubstituteDifferentOwner() public {
        positionManager.setWrongPositionOwner(true);
        vm.expectRevert("v4 adapter: position owner mismatch");
        _legacy(true);
    }

    function test_mintedPositionCannotSubstituteDifferentLiquidity() public {
        positionManager.setWrongPositionLiquidity(true);
        vm.expectRevert("v4 adapter: liquidity mismatch");
        _legacy(true);
    }

    function test_resultCannotSubstitutePositionManager() public {
        IArchLaunchLiquidityAdapter.SeedResult memory result = _legacy(true);
        result.positionManager = address(0xbad);
        _mockSeed(result);
        vm.expectRevert("v4 provisioner: result manager");
        _limited(true, block.timestamp, 0, 0, 0);
    }

    function test_resultCannotSubstitutePoolId() public {
        IArchLaunchLiquidityAdapter.SeedResult memory result = _legacy(true);
        result.poolId = bytes32(uint256(123));
        _mockSeed(result);
        vm.expectRevert("v4 provisioner: result pool");
        _limited(true, block.timestamp, 0, 0, 0);
    }

    function test_resultCannotSubstitutePermanentLockId() public {
        IArchLaunchLiquidityAdapter.SeedResult memory result = _legacy(true);
        result.lockId = 0;
        _mockSeed(result);
        vm.expectRevert("v4 provisioner: permanent custody");
        _limited(true, block.timestamp, 0, 0, 0);
    }

    function test_resultCannotReportConsumptionWithoutSpendingInputs() public {
        IArchLaunchLiquidityAdapter.SeedResult memory result = _legacy(true);
        _mockSeed(result);
        uint256 tokenBalance = token.balanceOf(address(this));
        vm.expectRevert("v4 provisioner: token result");
        _limited(true, block.timestamp, 0, 0, 0);
        assertEq(token.balanceOf(address(this)), tokenBalance);
        _assertNoResidueOrApprovals();
    }

    function test_resultCannotSubstituteTimedLockOwner() public {
        IArchLaunchLiquidityAdapter.SeedResult memory result = _legacy(false);
        ArchV4PositionLocker.Lock memory lock = locker.getLock(result.lockId);
        lock.owner = address(0xbad);
        vm.mockCall(address(locker), abi.encodeCall(locker.getLock, (result.lockId)), abi.encode(lock));
        _mockSeed(result);
        vm.expectRevert("v4 provisioner: lock mismatch");
        _limited(false, block.timestamp, 0, 0, 0);
    }

    function test_resultCannotAttachSubscriberToPosition() public {
        IArchLaunchLiquidityAdapter.SeedResult memory result = _legacy(true);
        positionManager.setSubscriber(result.positionIdOrAmount, address(0xbad));
        _mockSeed(result);
        vm.expectRevert("v4 provisioner: position subscribed");
        _limited(true, block.timestamp, 0, 0, 0);
    }

    function testFuzz_partialConsumptionSatisfiesActualInputMinima(uint16 consumption) public {
        uint16 bps = uint16(bound(consumption, 1, 10_000));
        positionManager.setConsumptionBps(bps);
        uint256 expectedTokenUsed = TOKEN_AMOUNT * bps / 10_000;
        uint256 expectedWethUsed = WETH_AMOUNT * bps / 10_000;
        IArchLaunchLiquidityAdapter.SeedResult memory result =
            _limited(true, block.timestamp, expectedTokenUsed, expectedWethUsed, 1);
        assertEq(result.tokenUsed, expectedTokenUsed);
        assertEq(result.wethUsed, expectedWethUsed);
        _assertNoResidueOrApprovals();
    }

    function _limited(bool permanent, uint256 deadline, uint256 minToken, uint256 minWeth, uint128 minLiquidity)
        private
        returns (IArchLaunchLiquidityAdapter.SeedResult memory result)
    {
        result = provisioner.addLiquidityWithLimits{value: WETH_AMOUNT}(
            token,
            TOKEN_AMOUNT,
            _expectedMarket,
            1,
            type(uint160).max,
            permanent ? 0 : 30 days,
            permanent,
            ArchV4UserLiquidityProvisioner.LiquidityLimits(deadline, minToken, minWeth, minLiquidity)
        );
        _expectedMarket = address(poolManager);
    }

    function _mockSeed(IArchLaunchLiquidityAdapter.SeedResult memory result) private {
        vm.mockCall(address(adapter), abi.encodeWithSelector(adapter.seedUserLiquidity.selector), abi.encode(result));
    }

    function test_limitsRefundCallbackCannotReenterEitherLiquiditySelector() public {
        V4SafetyLiquidityWallet wallet = new V4SafetyLiquidityWallet(provisioner, token);
        token.transfer(address(wallet), TOKEN_AMOUNT);
        IArchLaunchLiquidityAdapter.SeedResult memory result = wallet.add{value: WETH_AMOUNT}(TOKEN_AMOUNT, true, false);
        assertTrue(wallet.attemptedLegacy());
        assertTrue(wallet.attemptedLimited());
        assertFalse(wallet.reentered());
        assertEq(wallet.legacyError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(wallet.limitedError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(positionManager.ownerOf(result.positionIdOrAmount), DEAD);
        _assertNoResidueOrApprovals();
    }

    function test_limitsRejectingRefundReceiverRollsBackMintAndRegistration() public {
        V4SafetyLiquidityWallet wallet = new V4SafetyLiquidityWallet(provisioner, token);
        token.transfer(address(wallet), TOKEN_AMOUNT);
        vm.expectRevert("v4 provisioner: refund failed");
        wallet.add{value: WETH_AMOUNT}(TOKEN_AMOUNT, false, true);
        assertEq(token.balanceOf(address(wallet)), TOKEN_AMOUNT);
        assertEq(positionManager.nextTokenId(), 1);
        assertEq(token.marketPairCount(), 0);
        _assertNoResidueOrApprovals();
    }

    function _legacy(bool permanent) private returns (IArchLaunchLiquidityAdapter.SeedResult memory result) {
        result = provisioner.addLiquidity{value: WETH_AMOUNT}(
            token, TOKEN_AMOUNT, _expectedMarket, 1, type(uint160).max, permanent ? 0 : 30 days, permanent
        );
        _expectedMarket = address(poolManager);
    }

    function _assertNoResidueOrApprovals() private view {
        assertEq(token.balanceOf(address(provisioner)), 0);
        assertEq(weth.balanceOf(address(provisioner)), 0);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(token.allowance(address(provisioner), address(adapter)), 0);
        assertEq(weth.allowance(address(provisioner), address(adapter)), 0);
        assertEq(token.allowance(address(adapter), address(permit2)), 0);
        assertEq(weth.allowance(address(adapter), address(permit2)), 0);
        (uint160 tokenApproval, uint48 tokenExpiry) =
            permit2.allowance(address(adapter), address(token), address(positionManager));
        (uint160 wethApproval, uint48 wethExpiry) =
            permit2.allowance(address(adapter), address(weth), address(positionManager));
        assertEq(tokenApproval, 0);
        assertEq(tokenExpiry, 0);
        assertEq(wethApproval, 0);
        assertEq(wethExpiry, 0);
    }
}

contract V4SafetyLiquidityWallet {
    ArchV4UserLiquidityProvisioner public immutable provisioner;
    ArchToken public immutable token;
    bool public attemptedLegacy;
    bool public attemptedLimited;
    bool public reentered;
    bytes4 public legacyError;
    bytes4 public limitedError;
    bool private _probe;
    bool private _rejectRefund;

    constructor(ArchV4UserLiquidityProvisioner provisioner_, ArchToken token_) {
        provisioner = provisioner_;
        token = token_;
    }

    function add(uint256 amount, bool probe, bool rejectRefund)
        external
        payable
        returns (IArchLaunchLiquidityAdapter.SeedResult memory)
    {
        _probe = probe;
        _rejectRefund = rejectRefund;
        token.approve(address(provisioner), amount);
        return provisioner.addLiquidityWithLimits{value: msg.value}(
            token,
            amount,
            address(0),
            1,
            type(uint160).max,
            0,
            true,
            ArchV4UserLiquidityProvisioner.LiquidityLimits(block.timestamp, 0, 0, 1)
        );
    }

    receive() external payable {
        require(!_rejectRefund, "safety wallet: rejecting");
        if (!_probe || attemptedLegacy) return;
        attemptedLegacy = true;
        (bool legacyOk, bytes memory legacyData) = address(provisioner).call{value: 1}(
            abi.encodeCall(
                provisioner.addLiquidity,
                (token, uint256(1), address(0), uint160(1), type(uint160).max, uint64(0), true)
            )
        );
        attemptedLimited = true;
        (bool limitedOk, bytes memory limitedData) = address(provisioner).call{value: 1}(
            abi.encodeCall(
                provisioner.addLiquidityWithLimits,
                (
                    token,
                    uint256(1),
                    address(0),
                    uint160(1),
                    type(uint160).max,
                    uint64(0),
                    true,
                    ArchV4UserLiquidityProvisioner.LiquidityLimits(block.timestamp, 0, 0, 0)
                )
            )
        );
        reentered = legacyOk || limitedOk;
        if (legacyData.length >= 4) legacyError = bytes4(legacyData);
        if (limitedData.length >= 4) limitedError = bytes4(limitedData);
    }
}
