// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {IUniswapV4PoolManager, PoolKey} from "./interfaces/IUniswapV4.sol";

/// @title ArchV4SwapRouterAdapter
/// @notice Supported exact-input route for hookless ArchLiquid V4 launch pools.
///         It settles the amount that actually reaches PoolManager, allowing a
///         taxed sell to request the correct net input. A separately reviewed
///         exact-input router handles WETH-to-stock distribution purchases.
contract ArchV4SwapRouterAdapter is ISwapRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint24 public constant POOL_FEE = 3000;
    int24 public constant TICK_SPACING = 60;
    uint160 private constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    IUniswapV4PoolManager public immutable POOL_MANAGER;
    IERC20 public immutable WETH;
    IERC20 public immutable STOCK;
    ISwapRouter public immutable STOCK_ROUTER;

    struct CallbackData {
        address payer;
        address tokenIn;
        address tokenOut;
        address recipient;
        uint256 grossAmountIn;
        uint256 minAmountOut;
        uint160 sqrtPriceLimitX96;
    }

    constructor(IUniswapV4PoolManager poolManager, IERC20 weth, IERC20 stock, ISwapRouter stockRouter) {
        require(address(poolManager).code.length > 0, "v4 swap: invalid manager");
        require(address(weth).code.length > 0, "v4 swap: invalid weth");
        require(address(stock).code.length > 0 && address(stock) != address(weth), "v4 swap: invalid stock");
        require(address(stockRouter).code.length > 0, "v4 swap: invalid stock router");
        POOL_MANAGER = poolManager;
        WETH = weth;
        STOCK = stock;
        STOCK_ROUTER = stockRouter;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        require(msg.value == 0, "v4 swap: unexpected eth");
        require(p.recipient != address(0) && p.recipient != address(this), "v4 swap: invalid recipient");
        require(p.amountIn > 0, "v4 swap: zero input");

        if (p.tokenIn == address(WETH) && p.tokenOut == address(STOCK)) {
            require(p.fee == 0 && p.sqrtPriceLimitX96 == 0, "v4 swap: stock params");
            uint256 inputBefore = WETH.balanceOf(address(this));
            WETH.safeTransferFrom(msg.sender, address(this), p.amountIn);
            require(WETH.balanceOf(address(this)) == inputBefore + p.amountIn, "v4 swap: stock input mismatch");
            WETH.forceApprove(address(STOCK_ROUTER), p.amountIn);
            amountOut = STOCK_ROUTER.exactInputSingle(p);
            WETH.forceApprove(address(STOCK_ROUTER), 0);
            require(WETH.balanceOf(address(this)) == inputBefore, "v4 swap: stock input residue");
            return amountOut;
        }

        require(p.fee == POOL_FEE, "v4 swap: wrong fee");
        require(p.tokenIn == address(WETH) || p.tokenOut == address(WETH), "v4 swap: weth pair required");
        bytes memory response = POOL_MANAGER.unlock(
            abi.encode(
                CallbackData({
                    payer: msg.sender,
                    tokenIn: p.tokenIn,
                    tokenOut: p.tokenOut,
                    recipient: p.recipient,
                    grossAmountIn: p.amountIn,
                    minAmountOut: p.amountOutMinimum,
                    sqrtPriceLimitX96: p.sqrtPriceLimitX96
                })
            )
        );
        amountOut = abi.decode(response, (uint256));
    }

    /// @notice PoolManager callback. Input is synchronized and transferred
    ///         before the swap, so `paid` is the exact post-tax amount credited
    ///         to this router. The swap then consumes exactly that credit.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "v4 swap: only manager");
        CallbackData memory c = abi.decode(rawData, (CallbackData));
        require(c.payer != address(0) && c.tokenIn != c.tokenOut, "v4 swap: callback data");

        (PoolKey memory key, bool zeroForOne) = _poolKey(c.tokenIn, c.tokenOut);
        POOL_MANAGER.sync(c.tokenIn);
        IERC20(c.tokenIn).safeTransferFrom(c.payer, address(POOL_MANAGER), c.grossAmountIn);
        uint256 paid = POOL_MANAGER.settle();
        require(paid > 0 && paid <= uint256(type(int256).max), "v4 swap: invalid paid amount");

        uint160 limit = c.sqrtPriceLimitX96;
        if (limit == 0) limit = zeroForOne ? MIN_SQRT_PRICE_PLUS_ONE : MAX_SQRT_PRICE_MINUS_ONE;
        int256 delta = POOL_MANAGER.swap(
            key,
            IUniswapV4PoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(paid), sqrtPriceLimitX96: limit
            }),
            ""
        );

        (int128 delta0, int128 delta1) = _decodeDelta(delta);
        int128 outputDelta = zeroForOne ? delta1 : delta0;
        require(outputDelta > 0, "v4 swap: no output credit");
        uint256 grossOutput = uint128(outputDelta);

        IERC20 output = IERC20(c.tokenOut);
        uint256 adapterBefore = output.balanceOf(address(this));
        POOL_MANAGER.take(c.tokenOut, address(this), grossOutput);
        uint256 received = output.balanceOf(address(this)) - adapterBefore;
        require(received > 0, "v4 swap: no output received");

        uint256 recipientBefore = output.balanceOf(c.recipient);
        output.safeTransfer(c.recipient, received);
        uint256 amountOut = output.balanceOf(c.recipient) - recipientBefore;
        require(output.balanceOf(address(this)) == adapterBefore, "v4 swap: output residue");
        require(amountOut >= c.minAmountOut, "v4 swap: insufficient output");
        return abi.encode(amountOut);
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("v4 swap: multihop unsupported");
    }

    function _poolKey(address tokenIn, address tokenOut) private pure returns (PoolKey memory key, bool zeroForOne) {
        zeroForOne = tokenIn < tokenOut;
        key = PoolKey({
            currency0: zeroForOne ? tokenIn : tokenOut,
            currency1: zeroForOne ? tokenOut : tokenIn,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(0)
        });
    }

    function _decodeDelta(int256 delta) private pure returns (int128 amount0, int128 amount1) {
        amount0 = int128(delta >> 128);
        amount1 = int128(uint128(uint256(delta)));
    }
}
