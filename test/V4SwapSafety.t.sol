// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchV4SwapRouterAdapter} from "../src/ArchV4SwapRouterAdapter.sol";
import {IUniswapV4PoolManager, PoolKey} from "../src/interfaces/IUniswapV4.sol";
import {ISwapRouter} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {MockERC20, MockFeeToken, MockV3Router} from "./mocks/Mocks.sol";

interface ISwapUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Models V4's caller currency credits, including a price-limited partial
/// swap. Unlock must end with all credits settled, exactly as PoolManager does.
contract CreditPoolManager {
    error CurrencyNotSettled();
    mapping(address => int256) public credit;
    address private synced;
    uint256 private balanceBefore;
    address private input;
    address private output;
    uint256 public consumed;
    uint256 public produced;

    function configure(uint256 consumed_, uint256 produced_) external {
        consumed = consumed_;
        produced = produced_;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        result = ISwapUnlockCallback(msg.sender).unlockCallback(data);
        if (credit[input] != 0 || credit[output] != 0) revert CurrencyNotSettled();
    }

    function sync(address currency) external {
        synced = currency;
        balanceBefore = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(synced).balanceOf(address(this)) - balanceBefore;
        credit[synced] += int256(paid);
    }

    function swap(PoolKey calldata key, IUniswapV4PoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (int256 delta)
    {
        input = params.zeroForOne ? key.currency0 : key.currency1;
        output = params.zeroForOne ? key.currency1 : key.currency0;
        require(params.amountSpecified < 0, "mock: exact input");
        credit[input] -= int256(consumed);
        credit[output] += int256(produced);
        int128 inputDelta = -int128(int256(consumed));
        int128 outputDelta = int128(int256(produced));
        int128 delta0 = params.zeroForOne ? inputDelta : outputDelta;
        int128 delta1 = params.zeroForOne ? outputDelta : inputDelta;
        delta = (int256(delta0) << 128) | int256(uint256(uint128(delta1)));
    }

    function take(address currency, address recipient, uint256 amount) external {
        require(credit[currency] >= int256(amount), "mock: insufficient credit");
        credit[currency] -= int256(amount);
        require(IERC20(currency).transfer(recipient, amount), "mock: transfer");
    }
}

contract V4SwapSafetyTest is Test {
    CreditPoolManager manager;
    MockERC20 weth;
    MockERC20 token;
    MockERC20 stock;
    ArchV4SwapRouterAdapter router;
    address alice = makeAddr("swap alice");
    address recipient = makeAddr("swap recipient");

    function setUp() public {
        manager = new CreditPoolManager();
        weth = new MockERC20("Wrapped ETH", "WETH");
        token = new MockERC20("Launch", "LAUNCH");
        stock = new MockERC20("Stock", "STOCK");
        router = _router();
        weth.mint(alice, 10_000);
        token.mint(alice, 10_000);
        weth.mint(address(manager), 100_000);
        token.mint(address(manager), 100_000);
        vm.startPrank(alice);
        weth.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _router() private returns (ArchV4SwapRouterAdapter) {
        return new ArchV4SwapRouterAdapter(
            IUniswapV4PoolManager(address(manager)),
            IERC20(address(weth)),
            IERC20(address(stock)),
            ISwapRouter(address(new MockV3Router()))
        );
    }

    function _params(address input, address output, uint256 amount, uint256 minimum)
        private
        view
        returns (ISwapRouter.ExactInputSingleParams memory)
    {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: input,
            tokenOut: output,
            fee: 3000,
            recipient: recipient,
            amountIn: amount,
            amountOutMinimum: minimum,
            sqrtPriceLimitX96: 1
        });
    }

    function test_partialFillRefundsInputToPayer() public {
        manager.configure(40, 30);
        vm.prank(alice);
        uint256 received = router.exactInputSingle(_params(address(weth), address(token), 100, 30));
        assertEq(received, 30);
        assertEq(weth.balanceOf(alice), 9_960);
        assertEq(weth.balanceOf(recipient), 0);
        assertEq(token.balanceOf(recipient), 30);
        assertEq(manager.credit(address(weth)), 0);
        assertEq(manager.credit(address(token)), 0);
        assertEq(weth.balanceOf(address(router)), 0);
    }

    function test_partialFillReverseDirection() public {
        manager.configure(40, 30);
        vm.prank(alice);
        router.exactInputSingle(_params(address(token), address(weth), 100, 30));
        assertEq(token.balanceOf(alice), 9_960);
        assertEq(weth.balanceOf(recipient), 30);
        assertEq(manager.credit(address(token)), 0);
        assertEq(manager.credit(address(weth)), 0);
    }

    function test_fullFillPreservesBehaviorAndDonations() public {
        manager.configure(100, 30);
        weth.mint(address(router), 17);
        token.mint(address(router), 19);
        vm.prank(alice);
        router.exactInputSingle(_params(address(weth), address(token), 100, 30));
        assertEq(weth.balanceOf(alice), 9_900);
        assertEq(weth.balanceOf(address(router)), 17);
        assertEq(token.balanceOf(address(router)), 19);
    }

    function test_partialFillOutputMinimumFailureRollsBackEverything() public {
        manager.configure(40, 30);
        vm.prank(alice);
        vm.expectRevert("v4 swap: insufficient output");
        router.exactInputSingle(_params(address(weth), address(token), 100, 31));
        assertEq(weth.balanceOf(alice), 10_000);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(manager.credit(address(weth)), 0);
    }

    function test_taxedInputUsesPostTaxCreditAndRefundsRemainder() public {
        MockFeeToken taxed = new MockFeeToken();
        taxed.mint(alice, 10_000);
        manager.configure(5_000, 30);
        vm.startPrank(alice);
        taxed.approve(address(router), 10_000);
        router.exactInputSingle(_params(address(taxed), address(weth), 10_000, 30));
        vm.stopPrank();
        assertEq(taxed.balanceOf(alice), 4_851); // 9,900 paid - 5,000 used; refund pays 1% tax.
        assertEq(taxed.balanceOf(address(manager)), 5_000);
        assertEq(manager.credit(address(taxed)), 0);
        assertEq(weth.balanceOf(recipient), 30);
    }

    function test_taxedOutputEnforcesNetRecipientAmount() public {
        MockFeeToken taxed = new MockFeeToken();
        taxed.mint(address(manager), 10_000);
        manager.configure(40, 10_000);
        vm.prank(alice);
        uint256 received = router.exactInputSingle(_params(address(weth), address(taxed), 100, 9_801));
        assertEq(received, 9_801);
        assertEq(taxed.balanceOf(recipient), 9_801);
        assertEq(taxed.balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(alice), 9_960);
    }

    function test_onlyManagerMayInvokeCallback() public {
        vm.expectRevert("v4 swap: only manager");
        router.unlockCallback("");
    }

    function test_rejectsConsumptionExceedingPaidInput() public {
        manager.configure(101, 30);
        vm.prank(alice);
        vm.expectRevert("v4 swap: input delta exceeds paid");
        router.exactInputSingle(_params(address(weth), address(token), 100, 0));
        assertEq(weth.balanceOf(alice), 10_000);
    }

    function test_rejectsZeroInputDeltaAndRollsBackPrepayment() public {
        manager.configure(0, 30);
        vm.prank(alice);
        vm.expectRevert("v4 swap: no input consumed");
        router.exactInputSingle(_params(address(weth), address(token), 100, 0));
        assertEq(weth.balanceOf(alice), 10_000);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(manager.credit(address(weth)), 0);
    }

    function test_rejectsZeroOutputAndRollsBackInputRefund() public {
        manager.configure(40, 0);
        vm.prank(alice);
        vm.expectRevert("v4 swap: no output credit");
        router.exactInputSingle(_params(address(weth), address(token), 100, 0));
        assertEq(weth.balanceOf(alice), 10_000);
        assertEq(manager.credit(address(weth)), 0);
    }

    function test_taxedOutputMinimumUsesNetAmountAndRollsBackRefund() public {
        MockFeeToken taxed = new MockFeeToken();
        taxed.mint(address(manager), 10_000);
        manager.configure(40, 10_000);
        vm.prank(alice);
        vm.expectRevert("v4 swap: insufficient output");
        router.exactInputSingle(_params(address(weth), address(taxed), 100, 9_802));
        assertEq(weth.balanceOf(alice), 10_000);
        assertEq(taxed.balanceOf(recipient), 0);
        assertEq(taxed.balanceOf(address(manager)), 10_000);
    }

    function testFuzz_partialFillConservesCredits(uint96 gross, uint96 used, uint96 out) public {
        gross = uint96(bound(gross, 2, 10_000));
        used = uint96(bound(used, 1, gross));
        out = uint96(bound(out, 1, 100_000));
        manager.configure(used, out);
        vm.prank(alice);
        router.exactInputSingle(_params(address(weth), address(token), gross, out));
        assertEq(weth.balanceOf(alice), 10_000 - used);
        assertEq(token.balanceOf(recipient), out);
        assertEq(manager.credit(address(weth)), 0);
        assertEq(manager.credit(address(token)), 0);
    }
}
