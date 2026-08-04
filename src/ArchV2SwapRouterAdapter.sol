// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {IUniswapV2Factory, IUniswapV2Pair} from "./interfaces/IUniswapV2.sol";

/// @title ArchV2SwapRouterAdapter
/// @notice Presents ArchToken's narrow exactInputSingle interface over a
///         canonical Uniswap V2 factory. It measures the amount that actually
///         reaches the pair, so taxed sells use the V2 supporting-fee model;
///         it also measures the recipient's net output for slippage protection.
contract ArchV2SwapRouterAdapter is ISwapRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2Factory public immutable FACTORY;

    constructor(IUniswapV2Factory factory) {
        require(address(factory).code.length > 0, "v2 swap: invalid factory");
        FACTORY = factory;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        require(msg.value == 0, "v2 swap: unexpected eth");
        require(p.tokenIn != address(0) && p.tokenOut != address(0) && p.tokenIn != p.tokenOut, "v2 swap: path");
        require(p.recipient != address(0) && p.recipient != address(this), "v2 swap: invalid recipient");
        require(p.amountIn > 0, "v2 swap: zero input");
        require(p.fee == 0 && p.sqrtPriceLimitX96 == 0, "v2 swap: unsupported params");

        address pairAddress = FACTORY.getPair(p.tokenIn, p.tokenOut);
        require(pairAddress != address(0) && pairAddress.code.length > 0, "v2 swap: no pair");
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        require(pair.factory() == address(FACTORY), "v2 swap: wrong factory");

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        bool zeroForOne = p.tokenIn == pair.token0();
        require(
            zeroForOne ? p.tokenOut == pair.token1() : p.tokenIn == pair.token1() && p.tokenOut == pair.token0(),
            "v2 swap: pair mismatch"
        );
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        require(reserveIn > 0 && reserveOut > 0, "v2 swap: empty pair");

        uint256 pairBalanceBefore = IERC20(p.tokenIn).balanceOf(pairAddress);
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, pairAddress, p.amountIn);
        uint256 amountInput = IERC20(p.tokenIn).balanceOf(pairAddress) - pairBalanceBefore;
        require(amountInput > 0, "v2 swap: no input received");

        uint256 amountInputWithFee = amountInput * 997;
        uint256 grossOut = (amountInputWithFee * reserveOut) / (reserveIn * 1000 + amountInputWithFee);
        require(grossOut > 0 && grossOut < reserveOut, "v2 swap: no output");

        IERC20 output = IERC20(p.tokenOut);
        uint256 adapterBefore = output.balanceOf(address(this));
        (uint256 amount0Out, uint256 amount1Out) = zeroForOne ? (uint256(0), grossOut) : (grossOut, uint256(0));
        pair.swap(amount0Out, amount1Out, address(this), "");
        uint256 received = output.balanceOf(address(this)) - adapterBefore;
        require(received > 0, "v2 swap: no output received");

        uint256 recipientBefore = output.balanceOf(p.recipient);
        output.safeTransfer(p.recipient, received);
        amountOut = output.balanceOf(p.recipient) - recipientBefore;
        require(output.balanceOf(address(this)) == adapterBefore, "v2 swap: output residue");
        require(amountOut >= p.amountOutMinimum, "v2 swap: insufficient output");
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("v2 swap: multihop unsupported");
    }
}
