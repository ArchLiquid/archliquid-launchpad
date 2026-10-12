// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {ArchPresale} from "../src/ArchPresale.sol";
import {ArchAdapterPresale} from "../src/ArchAdapterPresale.sol";
import {IArchLaunchLiquidityAdapter} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {MockERC20, MockWETH, MockV3Pool, MockPositionNFT, MockV3Router} from "./mocks/Mocks.sol";

// Keep new entry points behind a test interface so these regressions compile
// against the unmodified baseline as well as the hardened contracts.
interface ISafetyPresale {
    function START() external view returns (uint64);
    function END() external view returns (uint64);
    function FINALIZATION_GRACE_PERIOD() external view returns (uint64);
    function finalizationDeadline() external view returns (uint64);
    function quoteContribution(uint256 amount) external view returns (uint256);
    function contribute() external payable;
    function finalize() external;
    function cancel() external;
    function refund() external;
    function refundTo(address payable recipient) external;
    function claim() external;
    function claimTeam() external;
    function contributed(address who) external view returns (uint256);
    function finalized() external view returns (bool);
    function canceled() external view returns (bool);
    function totalRaised() external view returns (uint256);
    function token() external view returns (address);
    function SALE_TOKENS() external view returns (uint256);
    function LP_TOKENS() external view returns (uint256);
    function TEAM_TOKENS() external view returns (uint256);
}

contract SafetyTreasury {
    bool public rejects;

    function setRejects(bool value) external {
        rejects = value;
    }

    receive() external payable {
        require(!rejects, "safety: treasury rejected");
    }
}

contract SafetyNFPM is MockPositionNFT {
    enum Failure {
        None,
        Initialize,
        Mint,
        ZeroId,
        ZeroLiquidity,
        ZeroAmount,
        OverflowAmount,
        FalseConsumption
    }
    address public immutable weth;
    Failure public failure;
    uint256 public tokenBps = 10_000;
    uint256 public wethBps = 10_000;
    uint256 public nextId = 1;
    mapping(bytes32 => address) private pools;

    constructor(address weth_) {
        weth = weth_;
    }

    function setFailure(Failure value) external {
        failure = value;
    }

    function setConsumption(uint256 tokens, uint256 wrapped) external {
        tokenBps = tokens;
        wethBps = wrapped;
    }

    function createAndInitializePoolIfNecessary(address a, address b, uint24 fee, uint160 price)
        external
        payable
        returns (address pool)
    {
        require(failure != Failure.Initialize, "safety: dependency failed");
        bytes32 key = keccak256(abi.encode(a, b, fee));
        pool = pools[key];
        if (pool == address(0)) {
            pool = address(new MockV3Pool(price));
            pools[key] = pool;
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(failure != Failure.Mint, "safety: dependency failed");
        amount0 = p.amount0Desired * (p.token0 == weth ? wethBps : tokenBps) / 10_000;
        amount1 = p.amount1Desired * (p.token1 == weth ? wethBps : tokenBps) / 10_000;
        address pool = pools[keccak256(abi.encode(p.token0, p.token1, p.fee))];
        IERC20(p.token0).transferFrom(msg.sender, pool, amount0);
        IERC20(p.token1).transferFrom(msg.sender, pool, amount1);
        tokenId = failure == Failure.ZeroId ? 0 : nextId++;
        _mint(p.recipient, tokenId);
        liquidity = failure == Failure.ZeroLiquidity ? 0 : 1e18;
        if (failure == Failure.ZeroAmount) amount0 = 0;
        if (failure == Failure.OverflowAmount) amount1 = p.amount1Desired + 1;
        if (failure == Failure.FalseConsumption) amount0 -= 1;
    }
}

contract SafetyAdapter is IArchLaunchLiquidityAdapter {
    address public immutable weth;
    bool public failsProvisioning;
    bool public failsSeed;
    bool public invalidResult;
    bool public underreportToken;
    bool public underreportWeth;

    constructor(address weth_) {
        weth = weth_;
    }

    function setFailures(bool provisioning, bool seedFailure, bool resultFailure) external {
        failsProvisioning = provisioning;
        failsSeed = seedFailure;
        invalidResult = resultFailure;
    }

    function setUnderreporting(bool tokenInput, bool wrappedInput) external {
        underreportToken = tokenInput;
        underreportWeth = wrappedInput;
    }

    function liquidityProvisioner() external view returns (address) {
        require(!failsProvisioning, "safety: dependency failed");
        return address(this);
    }

    function validateSeedAmounts(uint256 tokens, uint256 wrapped) external pure {
        require(tokens > 0 && wrapped > 0, "safety: zero seed");
    }

    function seed(SeedParams calldata p) external returns (SeedResult memory result) {
        require(!failsSeed, "safety: dependency failed");
        IERC20(p.token).transferFrom(msg.sender, address(this), p.tokenAmount);
        IERC20(weth).transferFrom(msg.sender, address(this), p.wethAmount);
        result = SeedResult(
            address(this),
            bytes32(uint256(1)),
            address(this),
            1,
            0,
            invalidResult ? 0 : (underreportToken ? p.tokenAmount / 2 : p.tokenAmount),
            underreportWeth ? p.wethAmount - 1 : p.wethAmount
        );
    }
}

contract SafetyRefundWallet {
    function contribute(ISafetyPresale sale) external payable {
        sale.contribute{value: msg.value}();
    }

    function refund(ISafetyPresale sale) external {
        sale.refund();
    }

    function route(ISafetyPresale sale, address payable recipient) external {
        sale.refundTo(recipient);
    }

    receive() external payable {
        revert("safety: wallet rejects native");
    }
}

contract SafetyRefundReceiver {
    ISafetyPresale public sale;
    bool public rejects;
    bool public reenters;
    bool public revertOnReentry;
    bool public reentrySucceeded;
    uint256 public received;

    function configure(ISafetyPresale target, bool reject, bool reenter, bool rejectReentry) external {
        sale = target;
        rejects = reject;
        reenters = reenter;
        revertOnReentry = rejectReentry;
    }

    receive() external payable {
        require(!rejects, "safety: receiver rejected");
        received += msg.value;
        if (reenters) {
            (bool ok,) = address(sale).call(abi.encodeCall(ISafetyPresale.refundTo, (payable(address(this)))));
            reentrySucceeded = ok;
            if (revertOnReentry) require(ok, "safety: reentry rejected");
        }
    }
}

contract PresaleSafetyTest is Test {
    event Refunded(address indexed who, uint256 amount);
    event RefundRouted(address indexed contributor, address indexed recipient, uint256 amount);
    uint256 private constant SUPPLY = 1_000_000e18;
    address private creator;
    address private alice;
    address private bob;
    SafetyTreasury private treasury;
    MockWETH private weth;
    MockERC20 private stock;
    MockV3Router private router;
    ArchV3PositionLocker private locker;
    SafetyNFPM private nfpm;
    SafetyAdapter private adapter;

    function setUp() public {
        vm.warp(1_000_000);
        creator = makeAddr("creator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        treasury = new SafetyTreasury();
        weth = new MockWETH();
        stock = new MockERC20("Stock", "STOCK");
        router = new MockV3Router();
        locker = new ArchV3PositionLocker(0, payable(address(treasury)), address(this));
        nfpm = new SafetyNFPM(address(weth));
        adapter = new SafetyAdapter(address(weth));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function _create(bool adapted, uint256 supply, uint64 end) private returns (ISafetyPresale sale) {
        uint64 start = uint64(vm.getBlockTimestamp() + 1 hours);
        if (adapted) {
            ArchAdapterPresale.Infra memory infra = ArchAdapterPresale.Infra(
                payable(address(treasury)),
                adapter,
                ISwapRouter(address(router)),
                IWETH9(address(weth)),
                3000,
                3000,
                IArchStockSwapExecutor(address(router)),
                address(this)
            );
            ArchAdapterPresale.TokenConfig memory t =
                ArchAdapterPresale.TokenConfig("Sale", "SALE", supply, 300, stock, 0);
            ArchAdapterPresale.SaleConfig memory s =
                ArchAdapterPresale.SaleConfig(5 ether, 10 ether, start, end, 8 ether, 50, 40, 3000, 30 days, end, end);
            sale = ISafetyPresale(address(new ArchAdapterPresale(creator, infra, t, s)));
        } else {
            ArchPresale.Infra memory infra = ArchPresale.Infra(
                payable(address(treasury)),
                locker,
                INonfungiblePositionManager(address(nfpm)),
                ISwapRouter(address(router)),
                IWETH9(address(weth)),
                3000,
                IArchStockSwapExecutor(address(router)),
                address(this)
            );
            ArchPresale.TokenConfig memory t = ArchPresale.TokenConfig("Sale", "SALE", supply, 300, stock, 0);
            ArchPresale.SaleConfig memory s =
                ArchPresale.SaleConfig(5 ether, 10 ether, start, end, 8 ether, 50, 40, 3000, 30 days, end, end);
            sale = ISafetyPresale(address(new ArchPresale(creator, infra, t, s)));
            locker.setFeeExempt(address(sale), true);
        }
    }

    function _create(bool adapted) private returns (ISafetyPresale) {
        return _create(adapted, SUPPLY, uint64(vm.getBlockTimestamp() + 1 days));
    }

    function _fund(ISafetyPresale sale, uint256 amount) private {
        vm.warp(sale.START());
        vm.prank(alice);
        sale.contribute{value: amount}();
    }

    function _fill(ISafetyPresale sale) private {
        _fund(sale, 6 ether);
        vm.prank(bob);
        sale.contribute{value: 4 ether}();
    }

    function _reason(bool adapted, string memory reason) private pure returns (bytes memory) {
        return bytes(string.concat(adapted ? "adapter presale: " : "presale: ", reason));
    }

    function test_bothPermanentFailuresBecomeRefundableAfterDeadline() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 0;
            ISafetyPresale sale = _create(adapted);
            _fund(sale, 6 ether);
            if (adapted) adapter.setFailures(true, false, false);
            else nfpm.setFailure(SafetyNFPM.Failure.Initialize);
            vm.warp(sale.END());
            for (uint256 attempt; attempt < 2; ++attempt) {
                vm.expectRevert("safety: dependency failed");
                sale.finalize();
                assertFalse(sale.finalized());
                assertFalse(sale.canceled());
                assertEq(address(sale).balance, 6 ether);
            }
            vm.warp(uint256(sale.END()) + 7 days);
            sale.cancel();
            uint256 before = alice.balance;
            vm.prank(alice);
            sale.refund();
            assertEq(alice.balance - before, 6 ether);
            assertEq(sale.contributed(alice), 0);
        }
    }

    function test_v3PartialConsumptionRoutesDustAndClearsApprovals() public {
        ISafetyPresale sale = _create(false);
        _fill(sale);
        nfpm.setConsumption(7500, 9000);
        sale.finalize();
        IERC20 token = IERC20(sale.token());
        assertEq(weth.balanceOf(address(sale)), 0);
        assertEq(weth.allowance(address(sale), address(nfpm)), 0);
        assertEq(token.allowance(address(sale), address(nfpm)), 0);
        assertEq(address(treasury).balance, 0.3 ether + 0.97 ether);
        assertEq(token.balanceOf(address(sale)), sale.SALE_TOKENS() + sale.TEAM_TOKENS());
        assertEq(token.balanceOf(address(0xdEaD)), sale.LP_TOKENS() / 4);
        assertEq(locker.lockCount(), 1);
        assertEq(nfpm.ownerOf(locker.getLock(0).tokenId), address(locker));
        vm.prank(alice);
        sale.claim();
        vm.prank(bob);
        sale.claim();
        assertEq(token.balanceOf(alice), 300_000e18);
        assertEq(token.balanceOf(bob), 200_000e18);
    }

    function test_bothRejectZeroEntitlementContribution() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 0;
            ISafetyPresale sale = _create(adapted, 1e18, uint64(vm.getBlockTimestamp() + 1 days));
            vm.warp(sale.START());
            vm.prank(alice);
            vm.expectRevert(_reason(adapted, "contribution rounds to zero"));
            sale.contribute{value: 1}();
            assertEq(sale.contributed(alice), 0);
            assertEq(sale.totalRaised(), 0);
        }
    }

    function test_bothFinalizationAndCancellationHaveExclusiveDeadlineBoundary() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 1;
            ISafetyPresale sale = _create(adapted);
            _fill(sale);
            assertEq(sale.FINALIZATION_GRACE_PERIOD(), 7 days);
            assertEq(sale.finalizationDeadline(), uint256(sale.END()) + 7 days);
            vm.warp(uint256(sale.finalizationDeadline()) - 1);
            vm.expectRevert(_reason(adapted, "soft cap met"));
            sale.cancel();
            sale.finalize();
            assertTrue(sale.finalized());
            ISafetyPresale expired = _create(adapted);
            _fill(expired);
            vm.warp(expired.finalizationDeadline());
            vm.expectRevert(_reason(adapted, "finalization expired"));
            expired.finalize();
            expired.cancel();
            assertTrue(expired.canceled());
            vm.expectRevert(_reason(adapted, "already settled"));
            expired.finalize();
            vm.expectRevert(_reason(adapted, "already settled"));
            expired.cancel();
        }
    }

    function test_bothSoftCapMissStillCancelsAtEndAndNotBefore() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 1;
            ISafetyPresale sale = _create(adapted);
            _fund(sale, 1 ether);
            vm.warp(uint256(sale.END()) - 1);
            vm.expectRevert(_reason(adapted, "not ended"));
            sale.cancel();
            vm.warp(sale.END());
            sale.cancel();
            assertTrue(sale.canceled());
            vm.prank(alice);
            sale.refund();
            assertEq(address(sale).balance, 0);
        }
    }

    function test_bothRefundToSupportsRejectingWalletAndCannotTakeAnotherContribution() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 1;
            ISafetyPresale sale = _create(adapted);
            SafetyRefundWallet wallet = new SafetyRefundWallet();
            vm.warp(sale.START());
            wallet.contribute{value: 1 ether}(sale);
            vm.prank(alice);
            sale.contribute{value: 1 ether}();
            vm.warp(sale.END());
            sale.cancel();
            vm.expectRevert(_reason(adapted, "refund failed"));
            wallet.refund(sale);
            assertEq(sale.contributed(address(wallet)), 1 ether);
            uint256 before = bob.balance;
            wallet.route(sale, payable(bob));
            assertEq(bob.balance - before, 1 ether);
            assertEq(sale.contributed(alice), 1 ether);
            vm.expectRevert(_reason(adapted, "nothing to refund"));
            wallet.route(sale, payable(bob));
            vm.prank(bob);
            vm.expectRevert(_reason(adapted, "nothing to refund"));
            sale.refundTo(payable(bob));
            vm.prank(alice);
            sale.refund();
            assertEq(address(sale).balance, 0);
        }
    }

    function test_bothRefundReceiverFailuresRollbackAndBlockedReentryCannotDoublePay() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 1;
            ISafetyPresale sale = _create(adapted);
            _fund(sale, 1 ether);
            SafetyRefundReceiver receiver = new SafetyRefundReceiver();
            vm.deal(address(receiver), 1 ether);
            vm.prank(address(receiver));
            sale.contribute{value: 1 ether}();
            vm.warp(sale.END());
            sale.cancel();
            vm.prank(alice);
            vm.expectRevert(_reason(adapted, "zero recipient"));
            sale.refundTo(payable(address(0)));
            receiver.configure(sale, true, false, false);
            vm.prank(alice);
            vm.expectRevert(_reason(adapted, "refund failed"));
            sale.refundTo(payable(address(receiver)));
            assertEq(sale.contributed(alice), 1 ether);
            assertEq(address(sale).balance, 2 ether);
            receiver.configure(sale, false, true, true);
            vm.prank(alice);
            vm.expectRevert(_reason(adapted, "refund failed"));
            sale.refundTo(payable(address(receiver)));
            assertEq(sale.contributed(alice), 1 ether);
            assertEq(receiver.received(), 0);
            receiver.configure(sale, false, true, false);
            vm.prank(alice);
            sale.refundTo(payable(address(receiver)));
            assertFalse(receiver.reentrySucceeded());
            assertEq(receiver.received(), 1 ether);
            assertEq(sale.contributed(alice), 0);
            assertEq(address(sale).balance, 1 ether);
            assertEq(sale.contributed(address(receiver)), 1 ether);
            vm.prank(address(receiver));
            sale.refundTo(payable(bob));
            assertEq(address(sale).balance, 0);
        }
    }

    function test_bothRefundRequiresCancellationAndCannotFollowFinalization() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 1;
            ISafetyPresale sale = _create(adapted);
            _fill(sale);
            vm.prank(alice);
            vm.expectRevert(_reason(adapted, "not canceled"));
            sale.refundTo(payable(alice));
            sale.finalize();
            vm.warp(sale.finalizationDeadline());
            vm.expectRevert(_reason(adapted, "already settled"));
            sale.cancel();
            vm.prank(alice);
            vm.expectRevert(_reason(adapted, "not canceled"));
            sale.refund();
        }
    }

    function test_bothQuoteMatchesRoundingAndAccumulatedEntitlement() public {
        for (uint256 i; i < 2; ++i) {
            ISafetyPresale sale = _create(i == 1, 1e18, uint64(vm.getBlockTimestamp() + 1 days));
            assertEq(sale.quoteContribution(0), 0);
            assertEq(sale.quoteContribution(19), 0);
            assertEq(sale.quoteContribution(20), 1);
            assertEq(sale.quoteContribution(1 ether), 5e16);
            _fund(sale, 20);
            vm.prank(alice);
            sale.contribute{value: 1}();
            assertEq(sale.contributed(alice), 21);
            assertEq(sale.quoteContribution(21), 1);
        }
    }

    function test_bothUnderfilledSalePreservesRoundedClaimsAndTeamAllocation() public {
        for (uint256 i; i < 2; ++i) {
            ISafetyPresale sale = _create(i == 1, 1e18, uint64(vm.getBlockTimestamp() + 1 days));
            _fund(sale, 3 ether + 17);
            vm.prank(bob);
            sale.contribute{value: 3 ether + 13}();
            if (i == 0) nfpm.setConsumption(7500, 9000);
            vm.warp(sale.END());
            uint256 aliceClaim = sale.quoteContribution(sale.contributed(alice));
            uint256 bobClaim = sale.quoteContribution(sale.contributed(bob));
            uint256 sold = sale.quoteContribution(sale.totalRaised());
            sale.finalize();
            IERC20 token = IERC20(sale.token());
            assertEq(token.balanceOf(address(sale)), sold + sale.TEAM_TOKENS());
            vm.prank(alice);
            sale.claim();
            vm.prank(bob);
            sale.claim();
            vm.prank(creator);
            sale.claimTeam();
            assertEq(token.balanceOf(alice), aliceClaim);
            assertEq(token.balanceOf(bob), bobClaim);
            assertEq(token.balanceOf(creator), sale.TEAM_TOKENS());
            // Aggregate and per-wallet floor rounding differ by one unit here.
            assertEq(token.balanceOf(address(sale)), sold - aliceClaim - bobClaim);
            assertEq(token.balanceOf(address(sale)), 1);
        }
    }

    function testFuzz_bothSplitWalletClaimsRemainSolventAfterPartialSettlement(
        uint128 firstAmount,
        uint128 secondAmount,
        uint16 tokenConsumptionBps,
        uint16 wethConsumptionBps
    ) public {
        uint256 first = bound(uint256(firstAmount), 2 ether, 4 ether);
        uint256 second = bound(uint256(secondAmount), 3 ether, 4 ether);
        uint256 tokenBps = bound(uint256(tokenConsumptionBps), 2500, 10_000);
        uint256 wethBps = bound(uint256(wethConsumptionBps), 2500, 10_000);
        for (uint256 i; i < 2; ++i) {
            ISafetyPresale sale = _create(i == 1, 1e18, uint64(vm.getBlockTimestamp() + 1 days));
            _fund(sale, first);
            vm.prank(bob);
            sale.contribute{value: second}();
            if (i == 0) nfpm.setConsumption(tokenBps, wethBps);
            uint256 firstClaim = sale.quoteContribution(first);
            uint256 secondClaim = sale.quoteContribution(second);
            uint256 team = sale.TEAM_TOKENS();
            uint256 treasuryBefore = address(treasury).balance;
            vm.warp(sale.END());
            sale.finalize();
            IERC20 token = IERC20(sale.token());
            // Every contributor liability and the full team allocation survive
            // settlement, even when the NFT consumes only part of its budget.
            assertGe(token.balanceOf(address(sale)), firstClaim + secondClaim + team);
            vm.prank(alice);
            sale.claim();
            vm.prank(bob);
            sale.claim();
            vm.prank(creator);
            sale.claimTeam();
            assertEq(token.balanceOf(alice), firstClaim);
            assertEq(token.balanceOf(bob), secondClaim);
            assertEq(token.balanceOf(creator), team);
            assertLe(token.balanceOf(address(sale)), 1);
            assertEq(address(sale).balance, 0);
            assertEq(weth.balanceOf(address(sale)), 0);
            uint256 raised = first + second;
            uint256 fee = raised * 300 / 10_000;
            uint256 wethUsed = i == 0 ? (raised - fee) * wethBps / 10_000 : raised - fee;
            assertEq(address(treasury).balance - treasuryBefore + wethUsed, raised);
        }
    }

    function test_v3MissingLockerFeeExemptionRollsBackMintThenTimeoutRefunds() public {
        locker = new ArchV3PositionLocker(1 ether, payable(address(treasury)), address(this));
        ISafetyPresale sale = _create(false);
        locker.setFeeExempt(address(sale), false);
        _fill(sale);
        vm.expectRevert("locker: wrong fee");
        sale.finalize();
        assertFalse(sale.finalized());
        assertEq(address(sale).balance, 10 ether);
        assertEq(weth.balanceOf(address(sale)), 0);
        assertEq(nfpm.nextId(), 1);
        assertEq(locker.lockCount(), 0);
        vm.warp(sale.finalizationDeadline());
        sale.cancel();
        vm.prank(alice);
        sale.refund();
        vm.prank(bob);
        sale.refund();
        assertEq(address(sale).balance, 0);
    }

    function test_bothRejectUnrepresentableDeadlineAtConstruction() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 1;
            vm.expectRevert(_reason(adapted, "deadline overflow"));
            _create(adapted, SUPPLY, type(uint64).max);
            ISafetyPresale sale = _create(adapted, SUPPLY, type(uint64).max - uint64(7 days));
            assertEq(sale.finalizationDeadline(), type(uint64).max);
        }
    }

    function test_bothTreasuryFailureRollsBackEntireSettlementThenTimeoutRefunds() public {
        for (uint256 i; i < 2; ++i) {
            bool adapted = i == 1;
            ISafetyPresale sale = _create(adapted);
            _fill(sale);
            treasury.setRejects(true);
            if (!adapted) nfpm.setConsumption(7500, 9000);
            vm.expectRevert(_reason(adapted, "fee send failed"));
            sale.finalize();
            assertFalse(sale.finalized());
            assertEq(sale.token(), address(0));
            assertEq(address(sale).balance, 10 ether);
            assertEq(weth.balanceOf(address(sale)), 0);
            vm.warp(sale.finalizationDeadline());
            sale.cancel();
            vm.prank(alice);
            sale.refund();
            vm.prank(bob);
            sale.refund();
            assertEq(address(sale).balance, 0);
            treasury.setRejects(false);
        }
    }

    function test_v3MintFailuresAndFalseReportsKeepEntirePrincipalRefundable() public {
        SafetyNFPM.Failure[6] memory failures = [
            SafetyNFPM.Failure.Mint,
            SafetyNFPM.Failure.ZeroId,
            SafetyNFPM.Failure.ZeroLiquidity,
            SafetyNFPM.Failure.ZeroAmount,
            SafetyNFPM.Failure.OverflowAmount,
            SafetyNFPM.Failure.FalseConsumption
        ];
        for (uint256 i; i < failures.length; ++i) {
            ISafetyPresale sale = _create(false);
            _fill(sale);
            nfpm.setFailure(failures[i]);
            vm.expectRevert();
            sale.finalize();
            assertFalse(sale.finalized());
            assertEq(address(sale).balance, 10 ether);
            assertEq(weth.balanceOf(address(sale)), 0);
            vm.warp(sale.finalizationDeadline());
            sale.cancel();
            vm.prank(alice);
            sale.refund();
            vm.prank(bob);
            sale.refund();
            assertEq(address(sale).balance, 0);
        }
    }

    function test_adapterSeedFailureStillImmediatelyCancelsAndRestoresNativePrincipal() public {
        ISafetyPresale sale = _create(true);
        _fill(sale);
        adapter.setFailures(false, true, false);
        sale.finalize();
        assertTrue(sale.canceled());
        assertFalse(sale.finalized());
        assertEq(address(sale).balance, 10 ether);
        assertEq(weth.balanceOf(address(sale)), 0);
        assertEq(weth.allowance(address(sale), address(adapter)), 0);
        vm.prank(alice);
        sale.refund();
        vm.prank(bob);
        sale.refund();
        assertEq(address(sale).balance, 0);
    }

    function test_adapterInvalidSuccessfulSeedCanBeRecoveredAfterDeadline() public {
        ISafetyPresale sale = _create(true);
        _fill(sale);
        adapter.setFailures(false, false, true);
        vm.expectRevert("adapter presale: empty seed");
        sale.finalize();
        assertFalse(sale.finalized());
        assertFalse(sale.canceled());
        assertEq(address(sale).balance, 10 ether);
        vm.warp(sale.finalizationDeadline());
        sale.cancel();
        vm.prank(alice);
        sale.refund();
        vm.prank(bob);
        sale.refund();
        assertEq(address(sale).balance, 0);
    }

    function test_adapterFalseConsumptionCannotBurnClaimAllocationsAndPrincipalRemainsRefundable() public {
        for (uint256 i; i < 2; ++i) {
            ISafetyPresale sale = _create(true);
            _fill(sale);
            adapter.setUnderreporting(i == 0, i == 1);
            vm.expectRevert(
                bytes(i == 0 ? "adapter presale: token input mismatch" : "adapter presale: weth input mismatch")
            );
            sale.finalize();
            assertFalse(sale.finalized());
            assertFalse(sale.canceled());
            assertEq(sale.token(), address(0));
            assertEq(address(sale).balance, 10 ether);
            assertEq(weth.balanceOf(address(sale)), 0);
            assertEq(weth.balanceOf(address(adapter)), 0);
            vm.warp(sale.finalizationDeadline());
            sale.cancel();
            vm.prank(alice);
            sale.refund();
            vm.prank(bob);
            sale.refund();
            assertEq(address(sale).balance, 0);
        }
    }

    function test_bothReceiveRejectsDirectNativeTransfer() public {
        for (uint256 i; i < 2; ++i) {
            ISafetyPresale sale = _create(i == 1);
            (bool accepted,) = address(sale).call{value: 1}("");
            assertFalse(accepted);
            assertEq(address(sale).balance, 0);
        }
    }

    function test_bothRoutedRefundEventKeepsOriginalContributorIdentity() public {
        for (uint256 i; i < 2; ++i) {
            ISafetyPresale sale = _create(i == 1);
            _fund(sale, 1 ether);
            vm.warp(sale.END());
            sale.cancel();
            vm.expectEmit(true, false, false, true, address(sale));
            emit Refunded(alice, 1 ether);
            vm.expectEmit(true, true, false, true, address(sale));
            emit RefundRouted(alice, bob, 1 ether);
            vm.prank(alice);
            sale.refundTo(payable(bob));
        }
    }

    function test_bothDirectRefundsEmitOnlyLegacyRefundEvent() public {
        for (uint256 i; i < 2; ++i) {
            for (uint256 method; method < 2; ++method) {
                ISafetyPresale sale = _create(i == 1);
                _fund(sale, 1 ether);
                vm.warp(sale.END());
                sale.cancel();
                vm.recordLogs();
                vm.prank(alice);
                if (method == 0) sale.refund();
                else sale.refundTo(payable(alice));
                Vm.Log[] memory logs = vm.getRecordedLogs();
                assertEq(logs.length, 1);
                assertEq(logs[0].emitter, address(sale));
                assertEq(logs[0].topics.length, 2);
                assertEq(logs[0].topics[0], keccak256("Refunded(address,uint256)"));
                assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
                assertEq(abi.decode(logs[0].data, (uint256)), 1 ether);
                assertEq(sale.contributed(alice), 0);
            }
        }
    }
}
