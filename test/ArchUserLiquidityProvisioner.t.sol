// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchUserLiquidityProvisioner} from "../src/ArchUserLiquidityProvisioner.sol";
import {IArchLaunchLiquidityAdapter} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {MockERC20, MockWETH} from "./mocks/Mocks.sol";

contract MockDustLaunchAdapter is IArchLaunchLiquidityAdapter {
    IERC20 public immutable WRAPPED;
    address public provisioner;
    address public resultMarket;

    constructor(IERC20 wrapped) {
        WRAPPED = wrapped;
    }

    function bindProvisioner(address provisioner_) external {
        require(provisioner == address(0), "mock adapter: already bound");
        provisioner = provisioner_;
    }

    function setResultMarket(address resultMarket_) external {
        resultMarket = resultMarket_;
    }

    function liquidityProvisioner() external view returns (address) {
        return provisioner;
    }

    function weth() external view returns (address) {
        return address(WRAPPED);
    }

    function validateSeedAmounts(uint256 tokenAmount, uint256 wethAmount) external pure {
        require(tokenAmount > 1 && wethAmount > 1, "mock adapter: zero seed");
    }

    function seed(SeedParams calldata p) external returns (SeedResult memory result) {
        require(msg.sender == provisioner, "mock adapter: unauthorized");
        uint256 tokenUsed = p.tokenAmount / 2;
        uint256 wethUsed = p.wethAmount / 2;
        require(IERC20(p.token).transferFrom(msg.sender, address(this), tokenUsed), "mock adapter: token transfer");
        require(WRAPPED.transferFrom(msg.sender, address(this), wethUsed), "mock adapter: weth transfer");

        result = SeedResult({
            market: resultMarket == address(0) ? address(this) : resultMarket,
            poolId: bytes32(uint256(uint160(address(this)))),
            positionManager: address(this),
            positionIdOrAmount: 1,
            lockId: p.permanent ? type(uint256).max : 1,
            tokenUsed: tokenUsed,
            wethUsed: wethUsed
        });
    }
}

contract RejectingLiquidityProvider {
    ArchUserLiquidityProvisioner public immutable PROVISIONER;
    ArchToken public immutable TOKEN;
    address public immutable MARKET;

    constructor(ArchUserLiquidityProvisioner provisioner, ArchToken token, address market) {
        PROVISIONER = provisioner;
        TOKEN = token;
        MARKET = market;
    }

    function add(uint256 tokenAmount, uint256 nativeAmount) external {
        TOKEN.approve(address(PROVISIONER), tokenAmount);
        PROVISIONER.addLiquidity{value: nativeAmount}(TOKEN, tokenAmount, MARKET, 180 days, false);
    }

    receive() external payable {
        revert("reject refund");
    }
}

contract ReentrantLiquidityProvider {
    ArchUserLiquidityProvisioner public immutable PROVISIONER;
    ArchToken public immutable TOKEN;
    address public immutable MARKET;

    bool public attackRefund;
    bool public reentryBlocked;
    bytes4 public reentryError;

    constructor(ArchUserLiquidityProvisioner provisioner, ArchToken token, address market) {
        PROVISIONER = provisioner;
        TOKEN = token;
        MARKET = market;
    }

    function add(uint256 tokenAmount) external payable {
        TOKEN.approve(address(PROVISIONER), type(uint256).max);
        attackRefund = true;
        PROVISIONER.addLiquidity{value: msg.value}(TOKEN, tokenAmount, MARKET, 180 days, false);
        attackRefund = false;
    }

    receive() external payable {
        if (!attackRefund) return;
        attackRefund = false;
        (bool ok, bytes memory revertData) = address(PROVISIONER).call{value: 2}(
            abi.encodeCall(PROVISIONER.addLiquidity, (TOKEN, 2, MARKET, uint64(180 days), false))
        );
        reentryBlocked = !ok;
        if (!ok && revertData.length >= 4) {
            reentryError = bytes4(revertData);
        }
    }
}

contract ArchUserLiquidityProvisionerTest is Test {
    MockWETH private weth;
    MockERC20 private stock;
    MockDustLaunchAdapter private adapter;
    ArchUserLiquidityProvisioner private provisioner;
    ArchToken private token;

    address private outsider = makeAddr("outsider");

    receive() external payable {}

    function setUp() public {
        weth = new MockWETH();
        stock = new MockERC20("Stock", "STOCK");
        adapter = new MockDustLaunchAdapter(IERC20(address(weth)));
        provisioner = new ArchUserLiquidityProvisioner(adapter);
        adapter.bindProvisioner(address(provisioner));

        token = _newToken();
        token.setTaxExempt(address(adapter));
        token.setLiquidityProvisioner(address(provisioner));
        token.addMarketPair(address(adapter));
        token.finalizeWiring();
    }

    function test_refundCallbackCannotReenterAndLeavesNoFundsOrApprovals() public {
        ReentrantLiquidityProvider provider = new ReentrantLiquidityProvider(provisioner, token, address(adapter));
        token.transfer(address(provider), 100e18 + 2);

        provider.add{value: 1 ether}(100e18);

        assertTrue(provider.reentryBlocked(), "refund callback reentered provisioner");
        assertEq(provider.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(token.balanceOf(address(provider)), 50e18 + 2, "unused token input not refunded");
        assertEq(address(provider).balance, 0.5 ether, "unused native input not refunded");
        assertEq(token.balanceOf(address(provisioner)), 0, "token residue");
        assertEq(weth.balanceOf(address(provisioner)), 0, "weth residue");
        assertEq(token.allowance(address(provisioner), address(adapter)), 0, "token approval residue");
        assertEq(weth.allowance(address(provisioner), address(adapter)), 0, "weth approval residue");
    }

    function test_taxExemptionCannotBeAddedByUserOrAfterWiring() public {
        ArchToken unwired = _newToken();

        vm.prank(outsider);
        vm.expectRevert("arch: not factory");
        unwired.setTaxExempt(address(adapter));

        vm.expectRevert("arch: wiring finalized");
        token.setTaxExempt(address(provisioner));
    }

    function test_provisionerRejectsLegacyTokenWithoutAdapterExemption() public {
        ArchToken legacy = _newToken();
        legacy.addMarketPair(address(adapter));
        legacy.finalizeWiring();
        legacy.approve(address(provisioner), 1e18);

        vm.expectRevert("provisioner: adapter not exempt");
        provisioner.addLiquidity{value: 1 ether}(legacy, 1e18, address(adapter), 180 days, false);
    }

    function test_userCanCreateExactlyOneDeferredCanonicalMarket() public {
        ArchToken unpooled = _newToken();
        unpooled.setTaxExempt(address(adapter));
        unpooled.setLiquidityProvisioner(address(provisioner));
        unpooled.finalizeWiring();
        unpooled.approve(address(provisioner), 100e18);

        provisioner.addLiquidity{value: 1 ether}(unpooled, 100e18, address(0), 180 days, false);

        assertEq(unpooled.marketPairCount(), 1);
        assertTrue(unpooled.isMarketPair(address(adapter)));
        assertTrue(unpooled.isDividendExempt(address(adapter)));

        vm.expectRevert("provisioner: unregistered market");
        provisioner.addLiquidity{value: 1 ether}(unpooled, 1e18, address(stock), 180 days, false);
    }

    function test_onlyBoundProvisionerCanRegisterDeferredMarket() public {
        ArchToken unpooled = _newToken();
        unpooled.setLiquidityProvisioner(address(provisioner));
        unpooled.finalizeWiring();

        vm.prank(outsider);
        vm.expectRevert("arch: not provisioner");
        unpooled.registerInitialMarketPair(address(adapter));
    }

    function test_adapterMarketMismatchRevertsAllTransfersAndApprovals() public {
        adapter.setResultMarket(address(stock));
        token.approve(address(provisioner), 100e18);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;

        vm.expectRevert("provisioner: market mismatch");
        provisioner.addLiquidity{value: 1 ether}(token, 100e18, address(adapter), 180 days, false);

        assertEq(token.balanceOf(address(this)), tokenBefore);
        assertEq(address(this).balance, ethBefore);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(provisioner)), 0);
        assertEq(weth.balanceOf(address(provisioner)), 0);
        assertEq(token.allowance(address(provisioner), address(adapter)), 0);
        assertEq(weth.allowance(address(provisioner), address(adapter)), 0);
    }

    function test_rejectedNativeRefundRevertsAtomically() public {
        RejectingLiquidityProvider provider = new RejectingLiquidityProvider(provisioner, token, address(adapter));
        token.transfer(address(provider), 100e18);
        vm.deal(address(provider), 1 ether);

        vm.expectRevert("provisioner: refund failed");
        provider.add(100e18, 1 ether);

        assertEq(token.balanceOf(address(provider)), 100e18);
        assertEq(address(provider).balance, 1 ether);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(provisioner)), 0);
        assertEq(weth.balanceOf(address(provisioner)), 0);
    }

    function test_preexistingDonationsCannotBeClaimedAsCallerRefunds() public {
        token.transfer(address(provisioner), 7e18);
        weth.mint(address(provisioner), 3 ether);
        token.approve(address(provisioner), 100e18);

        provisioner.addLiquidity{value: 1 ether}(token, 100e18, address(adapter), 180 days, false);

        assertEq(token.balanceOf(address(provisioner)), 7e18, "preexisting token donation moved");
        assertEq(weth.balanceOf(address(provisioner)), 3 ether, "preexisting weth donation moved");
        assertEq(token.allowance(address(provisioner), address(adapter)), 0);
        assertEq(weth.allowance(address(provisioner), address(adapter)), 0);
    }

    function _newToken() private returns (ArchToken created) {
        ArchToken.DexConfig memory dex = ArchToken.DexConfig({
            swapRouter: ISwapRouter(address(adapter)),
            weth: IWETH9(address(weth)),
            tokenPoolFee: 0,
            stockPoolFee: 0,
            stockSwapExecutor: IArchStockSwapExecutor(address(adapter))
        });
        created = new ArchToken(
            "Provisioner Test",
            "PROV",
            1_000_000e18,
            300,
            IERC20(address(stock)),
            dex,
            payable(address(this)),
            address(this),
            0,
            address(this)
        );
    }
}
