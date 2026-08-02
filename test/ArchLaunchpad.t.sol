// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchLaunchpad} from "../src/ArchLaunchpad.sol";
import {ArchPresale} from "../src/ArchPresale.sol";
import {ArchPresaleDeployer} from "../src/ArchPresaleDeployer.sol";
import {ArchCurveDeployer} from "../src/ArchCurveDeployer.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {MockERC20, MockNFPM, MockV3Router, MockWETH} from "./mocks/Mocks.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

contract ArchLaunchpadTest is Test {
    uint256 constant LISTING_FEE = 0.1 ether;
    uint256 constant LOCK_FEE = 0.02 ether;
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

    uint64 start;
    uint64 end;

    function setUp() public {
        treasury = new ArchTreasury(address(this));
        locker = new ArchV3PositionLocker(LOCK_FEE, payable(address(treasury)), address(this));
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
        // authorize the launchpad to exempt its presales from the lock fee
        locker.setFactory(address(launchpad), true);

        start = uint64(block.timestamp + 1 hours);
        end = uint64(block.timestamp + 1 days);

        vm.deal(creator, 10 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _tokenCfg() internal view returns (ArchPresale.TokenConfig memory) {
        return ArchPresale.TokenConfig({
            name: "Drift",
            symbol: "DRIFT",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
    }

    function _saleCfg() internal view returns (ArchPresale.SaleConfig memory) {
        return ArchPresale.SaleConfig({
            softCap: 5 ether,
            hardCap: 10 ether,
            start: start,
            end: end,
            perWalletCap: 8 ether,
            salePct: 50,
            lpPct: 40,
            poolFee: FEE_TIER,
            lpLockDuration: 365 days,
            teamCliff: end + 90 days,
            teamEnd: end + 365 days
        });
    }

    function _create() internal returns (ArchPresale) {
        vm.prank(creator);
        address p = launchpad.createPresale{value: LISTING_FEE}(_tokenCfg(), _saleCfg());
        return ArchPresale(p);
    }

    function test_create_takesListingFee() public {
        _create();
        assertEq(address(treasury).balance, LISTING_FEE);
        assertEq(launchpad.presaleCount(), 1);
    }

    function test_create_wrongFeeReverts() public {
        vm.prank(creator);
        vm.expectRevert("launchpad: wrong fee");
        launchpad.createPresale{value: LISTING_FEE - 1}(_tokenCfg(), _saleCfg());
    }

    function test_create_unapprovedStockReverts() public {
        MockERC20 fake = new MockERC20("FAKE", "FAKE");
        ArchPresale.TokenConfig memory t = _tokenCfg();
        t.stock = IERC20(address(fake));
        vm.prank(creator);
        vm.expectRevert("registry: stock not approved");
        launchpad.createPresale{value: LISTING_FEE}(t, _saleCfg());
    }

    function test_presaleExemptFromLockFee() public {
        ArchPresale presale = _create();
        assertTrue(locker.feeExempt(address(presale)));
    }

    function test_fullFlow_finalizeAndClaim() public {
        ArchPresale presale = _create();
        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 6 ether}();
        vm.prank(bob);
        presale.contribute{value: 4 ether}(); // hits hard cap

        uint256 treasuryBefore = address(treasury).balance;
        presale.finalize();

        // 3% of the 10 ETH raise to treasury, rest is locked liquidity
        assertEq(address(treasury).balance - treasuryBefore, 0.3 ether);
        ArchToken token = presale.token();

        // the V3 position NFT is locked for the creator
        ArchV3PositionLocker.Lock memory l = locker.getLock(0);
        assertEq(l.owner, creator);
        assertEq(l.manager, address(nfpm));
        assertEq(nfpm.ownerOf(l.tokenId), address(locker));

        // contributors claim pro-rata at fixed price (50% of supply / 10 ETH)
        vm.prank(alice);
        presale.claim();
        vm.prank(bob);
        presale.claim();
        assertEq(token.balanceOf(alice), 300_000e18);
        assertEq(token.balanceOf(bob), 200_000e18);
        // sale fully filled: all 500k sale tokens distributed
        assertEq(token.balanceOf(presale.DEAD()), 0);
    }

    function test_doubleClaimReverts() public {
        ArchPresale presale = _fillAndFinalize();
        vm.startPrank(alice);
        presale.claim();
        vm.expectRevert("presale: already claimed");
        presale.claim();
        vm.stopPrank();
    }

    function test_underfilledBurnsUnsold() public {
        ArchPresale presale = _create();
        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 6 ether}(); // above soft cap, below hard cap
        vm.warp(end);
        presale.finalize();

        ArchToken token = presale.token();
        // sold = 6 ETH worth = 300k; sale allocation 500k; 200k burned
        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 300_000e18);
        assertEq(token.balanceOf(presale.DEAD()), 200_000e18);
    }

    function test_softCapMissed_refund() public {
        ArchPresale presale = _create();
        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 3 ether}(); // below soft cap
        vm.warp(end);

        vm.expectRevert("presale: soft cap missed");
        presale.finalize();

        presale.cancel();
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        presale.refund();
        assertEq(alice.balance - balBefore, 3 ether);
    }

    function test_cannotContributeAfterEnd() public {
        ArchPresale presale = _create();
        vm.warp(end);
        vm.prank(alice);
        vm.expectRevert("presale: not open");
        presale.contribute{value: 1 ether}();
    }

    function test_perWalletCapEnforced() public {
        ArchPresale presale = _create();
        vm.warp(start);
        vm.prank(alice);
        vm.expectRevert("presale: over wallet cap");
        presale.contribute{value: 9 ether}(); // cap is 8
    }

    function test_hardCapEnforced() public {
        ArchPresale presale = _create();
        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 6 ether}();
        vm.prank(bob);
        vm.expectRevert("presale: over hard cap");
        presale.contribute{value: 5 ether}();
    }

    function test_teamVesting_cliffThenLinear() public {
        ArchPresale presale = _fillAndFinalize();
        ArchToken token = presale.token();
        // team allocation = 10% of supply
        assertEq(presale.TEAM_TOKENS(), 100_000e18);

        // nothing before cliff
        vm.warp(end + 89 days);
        assertEq(presale.teamVested(), 0);
        vm.prank(creator);
        vm.expectRevert("presale: nothing vested");
        presale.claimTeam();

        // partial after cliff (cliff at +90d of a 365d linear from end)
        vm.warp(end + 180 days);
        uint256 expected = (uint256(100_000e18) * 180 days) / 365 days;
        assertApproxEqAbs(presale.teamVested(), expected, 1e12);
        vm.prank(creator);
        presale.claimTeam();
        assertApproxEqAbs(token.balanceOf(creator), expected, 1e12);

        // full at end
        vm.warp(end + 365 days);
        vm.prank(creator);
        presale.claimTeam();
        assertEq(token.balanceOf(creator), 100_000e18);
    }

    function test_teamClaim_onlyCreator() public {
        ArchPresale presale = _fillAndFinalize();
        vm.warp(end + 365 days);
        vm.prank(alice);
        vm.expectRevert("presale: not creator");
        presale.claimTeam();
    }

    function test_cannotFinalizeTwice() public {
        ArchPresale presale = _fillAndFinalize();
        vm.expectRevert("presale: already settled");
        presale.finalize();
    }

    /// @dev SECURITY: even though CREATE2 makes the launch token address
    ///      unpredictable, the price guard remains a safety net. If the launch
    ///      pool is somehow pre-initialized at a hostile price, finalize must
    ///      NOT seed into it (which would strand the raise); it cancels so every
    ///      contributor takes a full refund. Contributor ETH is never locked.
    function test_finalizeCancelsOnGriefedPool() public {
        ArchPresale presale = _create();
        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 6 ether}();
        vm.prank(bob);
        presale.contribute{value: 4 ether}();

        // model the launch pool having been pre-initialized at a hostile price
        nfpm.setGriefNext(true);

        // finalize does not revert or lock: it flips the sale to canceled
        presale.finalize();
        assertFalse(presale.finalized());
        assertTrue(presale.canceled());

        // both contributors recover 100% of their ETH
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        presale.refund();
        assertEq(alice.balance - aliceBefore, 6 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        presale.refund();
        assertEq(bob.balance - bobBefore, 4 ether);
    }

    function test_create_badTaxRevertsAtCreation() public {
        ArchPresale.TokenConfig memory t = _tokenCfg();
        t.taxBps = 600; // above MAX_TAX_BPS, would fail at finalize otherwise
        vm.prank(creator);
        vm.expectRevert("presale: tax out of range");
        launchpad.createPresale{value: LISTING_FEE}(t, _saleCfg());
    }

    function _fillAndFinalize() internal returns (ArchPresale presale) {
        presale = _create();
        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 6 ether}();
        vm.prank(bob);
        presale.contribute{value: 4 ether}();
        presale.finalize();
    }
}
