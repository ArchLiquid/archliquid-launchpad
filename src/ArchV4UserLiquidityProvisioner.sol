// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {ArchV4LaunchLiquidityAdapter} from "./ArchV4LaunchLiquidityAdapter.sol";
import {IArchLaunchLiquidityAdapter} from "./interfaces/IArchLaunchLiquidityAdapter.sol";
import {PoolKey} from "./interfaces/IUniswapV4.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";

/// @title ArchV4UserLiquidityProvisioner
/// @notice Permissionless, generation-bound V4 liquidity entry point. The
///         provider controls the locked position and supplies an execution-time
///         price corridor; no router, pool, hook or recipient is user-selectable.
contract ArchV4UserLiquidityProvisioner is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Caller bounds checked atomically against the position actually minted.
    struct LiquidityLimits {
        uint256 deadline;
        uint256 minTokenUsed;
        uint256 minWethUsed;
        uint128 minLiquidity;
    }

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
        return _addLiquidity(
            token,
            tokenAmount,
            expectedMarket,
            minimumSqrtPriceX96,
            maximumSqrtPriceX96,
            lockDuration,
            permanent,
            LiquidityLimits(type(uint256).max, 0, 0, 0)
        );
    }

    /// @notice Bounds expiry, each consumed input and minted liquidity in addition
    ///         to the execution price. Unused inputs are returned to the provider.
    function addLiquidityWithLimits(
        ArchToken token,
        uint256 tokenAmount,
        address expectedMarket,
        uint160 minimumSqrtPriceX96,
        uint160 maximumSqrtPriceX96,
        uint64 lockDuration,
        bool permanent,
        LiquidityLimits calldata limits
    ) external payable nonReentrant returns (IArchLaunchLiquidityAdapter.SeedResult memory result) {
        return _addLiquidity(
            token,
            tokenAmount,
            expectedMarket,
            minimumSqrtPriceX96,
            maximumSqrtPriceX96,
            lockDuration,
            permanent,
            limits
        );
    }

    function _addLiquidity(
        ArchToken token,
        uint256 tokenAmount,
        address expectedMarket,
        uint160 minimumSqrtPriceX96,
        uint160 maximumSqrtPriceX96,
        uint64 lockDuration,
        bool permanent,
        LiquidityLimits memory limits
    ) private returns (IArchLaunchLiquidityAdapter.SeedResult memory result) {
        require(block.timestamp <= limits.deadline, "v4 provisioner: expired");
        require(
            limits.minTokenUsed <= tokenAmount && limits.minWethUsed <= msg.value, "v4 provisioner: excessive minimum"
        );
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
        uint64 unlockTime = 0; // Permanent positions have no timed unlock.
        if (permanent) {
            require(lockDuration == 0, "v4 provisioner: permanent duration");
        } else {
            require(lockDuration > 0, "v4 provisioner: zero duration");
            require(block.timestamp <= type(uint64).max - lockDuration, "v4 provisioner: time overflow");
            unlockTime = uint64(block.timestamp) + lockDuration;
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
                unlockTime: unlockTime,
                permanent: permanent
            }),
            createsFirstMarket,
            minimumSqrtPriceX96,
            maximumSqrtPriceX96
        );
        launchToken.forceApprove(address(ADAPTER), 0);
        wrapped.forceApprove(address(ADAPTER), 0);

        require(result.market == canonicalMarket, "v4 provisioner: result market");
        _validatePosition(token, result, permanent, unlockTime, limits.minLiquidity);

        uint256 tokenAfter = launchToken.balanceOf(address(this));
        uint256 wethAfter = wrapped.balanceOf(address(this));
        require(tokenAfter >= tokenBefore && tokenAfter <= tokenBefore + tokenAmount, "v4 provisioner: token balance");
        require(wethAfter >= wethBefore && wethAfter <= wethBefore + msg.value, "v4 provisioner: weth balance");
        uint256 tokenRefund = tokenAfter - tokenBefore;
        uint256 wethRefund = wethAfter - wethBefore;
        uint256 tokenUsed = tokenAmount - tokenRefund;
        uint256 wethUsed = msg.value - wethRefund;
        require(tokenUsed > 0 && result.tokenUsed == tokenUsed, "v4 provisioner: token result");
        require(wethUsed > 0 && result.wethUsed == wethUsed, "v4 provisioner: weth result");
        require(tokenUsed >= limits.minTokenUsed && wethUsed >= limits.minWethUsed, "v4 provisioner: input minimum");
        if (createsFirstMarket) {
            token.registerInitialMarketPair(result.market);
            require(token.isMarketPair(result.market), "v4 provisioner: market registration");
        }

        if (tokenRefund > 0) launchToken.safeTransfer(msg.sender, tokenRefund);
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

    function _validatePosition(
        ArchToken token,
        IArchLaunchLiquidityAdapter.SeedResult memory result,
        bool permanent,
        uint64 unlockTime,
        uint128 minLiquidity
    ) private view {
        require(result.positionManager == address(ADAPTER.POSITION_MANAGER()), "v4 provisioner: result manager");
        require(result.positionIdOrAmount > 0, "v4 provisioner: empty position");
        bool tokenIs0 = address(token) < address(WETH);
        PoolKey memory expectedKey = PoolKey({
            currency0: tokenIs0 ? address(token) : address(WETH),
            currency1: tokenIs0 ? address(WETH) : address(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        bytes32 expectedPoolId = keccak256(abi.encode(expectedKey));
        require(result.poolId == expectedPoolId, "v4 provisioner: result pool");
        (PoolKey memory actualKey,) = ADAPTER.POSITION_MANAGER().getPoolAndPositionInfo(result.positionIdOrAmount);
        require(keccak256(abi.encode(actualKey)) == expectedPoolId, "v4 provisioner: position pool");
        uint128 liquidity = ADAPTER.POSITION_MANAGER().getPositionLiquidity(result.positionIdOrAmount);
        require(liquidity > 0 && liquidity >= minLiquidity, "v4 provisioner: liquidity minimum");
        require(
            ADAPTER.POSITION_MANAGER().subscriber(result.positionIdOrAmount) == address(0),
            "v4 provisioner: position subscribed"
        );
        address positionOwner = ADAPTER.POSITION_MANAGER().ownerOf(result.positionIdOrAmount);
        if (permanent) {
            require(
                result.lockId == type(uint256).max && positionOwner == ADAPTER.DEAD(),
                "v4 provisioner: permanent custody"
            );
        } else {
            ArchV4PositionLocker locker = ADAPTER.LOCKER();
            require(positionOwner == address(locker), "v4 provisioner: timed custody");
            ArchV4PositionLocker.Lock memory lock = locker.getLock(result.lockId);
            require(
                lock.tokenId == result.positionIdOrAmount && lock.owner == msg.sender && lock.unlockTime == unlockTime
                    && !lock.withdrawn && lock.currency0 == expectedKey.currency0
                    && lock.currency1 == expectedKey.currency1 && lock.hooks == address(0),
                "v4 provisioner: lock mismatch"
            );
        }
    }
}
