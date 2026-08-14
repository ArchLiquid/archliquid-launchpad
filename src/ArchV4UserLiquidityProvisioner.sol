// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {ArchV4LaunchLiquidityAdapter} from "./ArchV4LaunchLiquidityAdapter.sol";
import {IArchLaunchLiquidityAdapter} from "./interfaces/IArchLaunchLiquidityAdapter.sol";

/// @title ArchV4UserLiquidityProvisioner
/// @notice Permissionless, generation-bound V4 liquidity entry point. The
///         provider controls the locked position and supplies an execution-time
///         price corridor; no router, pool, hook or recipient is user-selectable.
contract ArchV4UserLiquidityProvisioner is ReentrancyGuard {
    using SafeERC20 for IERC20;

    ArchV4LaunchLiquidityAdapter public immutable ADAPTER;
    IWETH9 public immutable WETH;

    event UserLiquidityAdded(
        address indexed provider,
        address indexed token,
        address indexed market,
        bytes32 poolId,
        uint256 positionId,
        uint256 lockId,
        uint256 tokenUsed,
        uint256 wethUsed,
        bool permanent
    );

    constructor(ArchV4LaunchLiquidityAdapter adapter) {
        require(address(adapter).code.length > 0, "v4 provisioner: invalid adapter");
        address wrapped = adapter.weth();
        require(wrapped.code.length > 0, "v4 provisioner: invalid weth");
        ADAPTER = adapter;
        WETH = IWETH9(wrapped);
    }

    receive() external payable {
        require(msg.sender == address(WETH), "v4 provisioner: only weth");
    }

    /// @param expectedMarket Zero when creating this token's first market;
    ///        otherwise the adapter's fixed V4 PoolManager already registered
    ///        in the token.
    /// @param minimumSqrtPriceX96 Inclusive execution-price lower bound.
    /// @param maximumSqrtPriceX96 Inclusive execution-price upper bound.
    function addLiquidity(
        ArchToken token,
        uint256 tokenAmount,
        address expectedMarket,
        uint160 minimumSqrtPriceX96,
        uint160 maximumSqrtPriceX96,
        uint64 lockDuration,
        bool permanent
    ) external payable nonReentrant returns (IArchLaunchLiquidityAdapter.SeedResult memory result) {
        require(address(token).code.length > 0 && address(token) != address(WETH), "v4 provisioner: invalid token");
        require(tokenAmount > 0 && msg.value > 0, "v4 provisioner: zero input");
        require(minimumSqrtPriceX96 > 0, "v4 provisioner: zero minimum price");
        require(minimumSqrtPriceX96 <= maximumSqrtPriceX96, "v4 provisioner: invalid price bounds");
        require(token.wired(), "v4 provisioner: token not wired");
        require(token.liquidityProvisioner() == address(this), "v4 provisioner: wrong generation");
        require(token.isTaxExempt(address(ADAPTER)), "v4 provisioner: adapter not exempt");

        bool createsFirstMarket = token.marketPairCount() == 0;
        address canonicalMarket = address(ADAPTER.POOL_MANAGER());
        if (createsFirstMarket) {
            require(expectedMarket == address(0), "v4 provisioner: first market expectation");
        } else {
            require(expectedMarket == canonicalMarket, "v4 provisioner: market mismatch");
            require(token.isMarketPair(canonicalMarket), "v4 provisioner: unregistered market");
        }
        if (permanent) {
            require(lockDuration == 0, "v4 provisioner: permanent duration");
        } else {
            require(lockDuration > 0, "v4 provisioner: zero duration");
            require(block.timestamp <= type(uint64).max - lockDuration, "v4 provisioner: time overflow");
        }

        IERC20 launchToken = IERC20(address(token));
        IERC20 wrapped = IERC20(address(WETH));
        uint256 tokenBefore = launchToken.balanceOf(address(this));
        uint256 wethBefore = wrapped.balanceOf(address(this));

        launchToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
        require(launchToken.balanceOf(address(this)) == tokenBefore + tokenAmount, "v4 provisioner: token mismatch");
        WETH.deposit{value: msg.value}();
        require(wrapped.balanceOf(address(this)) == wethBefore + msg.value, "v4 provisioner: weth mismatch");

        launchToken.forceApprove(address(ADAPTER), tokenAmount);
        wrapped.forceApprove(address(ADAPTER), msg.value);
        result = ADAPTER.seedUserLiquidity(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(token),
                tokenAmount: tokenAmount,
                wethAmount: msg.value,
                lockOwner: permanent ? address(0) : msg.sender,
                unlockTime: permanent ? 0 : uint64(block.timestamp) + lockDuration,
                permanent: permanent
            }),
            createsFirstMarket,
            minimumSqrtPriceX96,
            maximumSqrtPriceX96
        );
        launchToken.forceApprove(address(ADAPTER), 0);
        wrapped.forceApprove(address(ADAPTER), 0);

        require(result.market == canonicalMarket, "v4 provisioner: result market");
        if (createsFirstMarket) {
            token.registerInitialMarketPair(result.market);
            require(token.isMarketPair(result.market), "v4 provisioner: market registration");
        }
        require(result.tokenUsed > 0 && result.tokenUsed <= tokenAmount, "v4 provisioner: token result");
        require(result.wethUsed > 0 && result.wethUsed <= msg.value, "v4 provisioner: weth result");
        require(result.positionIdOrAmount > 0, "v4 provisioner: empty position");

        uint256 tokenRefund = launchToken.balanceOf(address(this)) - tokenBefore;
        if (tokenRefund > 0) launchToken.safeTransfer(msg.sender, tokenRefund);
        uint256 wethRefund = wrapped.balanceOf(address(this)) - wethBefore;
        if (wethRefund > 0) {
            WETH.withdraw(wethRefund);
            (bool refunded,) = payable(msg.sender).call{value: wethRefund}("");
            require(refunded, "v4 provisioner: refund failed");
        }
        require(launchToken.balanceOf(address(this)) == tokenBefore, "v4 provisioner: token residue");
        require(wrapped.balanceOf(address(this)) == wethBefore, "v4 provisioner: weth residue");

        emit UserLiquidityAdded(
            msg.sender,
            address(token),
            result.market,
            result.poolId,
            result.positionIdOrAmount,
            result.lockId,
            result.tokenUsed,
            result.wethUsed,
            permanent
        );
    }
}
