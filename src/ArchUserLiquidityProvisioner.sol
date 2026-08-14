// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {IArchLaunchLiquidityAdapter} from "./interfaces/IArchLaunchLiquidityAdapter.sol";
import {IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

/// @title ArchUserLiquidityProvisioner
/// @notice Permissionless, family-specific entry point for adding liquidity to
///         an existing ArchToken/WETH launch market. It never accepts an
///         arbitrary router, adapter, market or recipient: the immutable
///         adapter creates the position and sends it only to the family locker
///         for `msg.sender`, or to the permanent burn address.
/// @dev The creating launch contract must mark ADAPTER tax-exempt before
///      finalizing token wiring. That makes the adapter's pool transfer exact
///      without creating a general-purpose tax bypass.
contract ArchUserLiquidityProvisioner is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IArchLaunchLiquidityAdapter public immutable ADAPTER;
    IWETH9 public immutable WETH;

    event UserLiquidityAdded(
        address indexed provider,
        address indexed token,
        address indexed market,
        bytes32 poolId,
        uint256 positionIdOrAmount,
        uint256 lockId,
        uint256 tokenUsed,
        uint256 wethUsed,
        bool permanent
    );

    constructor(IArchLaunchLiquidityAdapter adapter) {
        require(address(adapter).code.length > 0, "provisioner: invalid adapter");
        address wrapped = adapter.weth();
        require(wrapped.code.length > 0, "provisioner: invalid weth");
        ADAPTER = adapter;
        WETH = IWETH9(wrapped);
    }

    /// @dev Native ETH is accepted only while unwrapping a user's unused WETH.
    receive() external payable {
        require(msg.sender == address(WETH), "provisioner: only weth");
    }

    /// @param token Existing wired ArchToken whose registered launch market is
    ///        `expectedMarket`.
    /// @param tokenAmount Exact maximum token input approved by the provider.
    /// @param expectedMarket Canonical market already registered in `token`.
    /// @param lockDuration Duration from the mined block timestamp. Must be zero
    ///        for permanent liquidity; the family locker enforces its minimum.
    /// @param permanent Burn the LP position permanently instead of locking it.
    function addLiquidity(
        ArchToken token,
        uint256 tokenAmount,
        address expectedMarket,
        uint64 lockDuration,
        bool permanent
    ) external payable nonReentrant returns (IArchLaunchLiquidityAdapter.SeedResult memory result) {
        require(address(token).code.length > 0 && address(token) != address(WETH), "provisioner: invalid token");
        require(tokenAmount > 0 && msg.value > 0, "provisioner: zero input");
        require(token.wired(), "provisioner: token not wired");
        require(token.isTaxExempt(address(ADAPTER)), "provisioner: adapter not exempt");
        bool createsFirstMarket = token.marketPairCount() == 0;
        if (createsFirstMarket) {
            require(expectedMarket == address(0), "provisioner: first market expectation");
            require(token.liquidityProvisioner() == address(this), "provisioner: not bound");
        } else {
            require(expectedMarket.code.length > 0, "provisioner: invalid market");
            require(token.isMarketPair(expectedMarket), "provisioner: unregistered market");
        }
        if (permanent) {
            require(lockDuration == 0, "provisioner: permanent duration");
        } else {
            require(lockDuration > 0, "provisioner: zero duration");
            require(block.timestamp <= type(uint64).max - lockDuration, "provisioner: time overflow");
        }

        IERC20 launchToken = IERC20(address(token));
        IERC20 wrapped = IERC20(address(WETH));
        uint256 tokenBefore = launchToken.balanceOf(address(this));
        uint256 wethBefore = wrapped.balanceOf(address(this));

        launchToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
        require(launchToken.balanceOf(address(this)) == tokenBefore + tokenAmount, "provisioner: token mismatch");
        WETH.deposit{value: msg.value}();
        require(wrapped.balanceOf(address(this)) == wethBefore + msg.value, "provisioner: weth mismatch");

        launchToken.forceApprove(address(ADAPTER), tokenAmount);
        wrapped.forceApprove(address(ADAPTER), msg.value);
        result = ADAPTER.seed(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(token),
                tokenAmount: tokenAmount,
                wethAmount: msg.value,
                lockOwner: permanent ? address(0) : msg.sender,
                unlockTime: permanent ? 0 : uint64(block.timestamp) + lockDuration,
                permanent: permanent
            })
        );
        launchToken.forceApprove(address(ADAPTER), 0);
        wrapped.forceApprove(address(ADAPTER), 0);

        require(result.market.code.length > 0, "provisioner: invalid result market");
        if (createsFirstMarket) {
            token.registerInitialMarketPair(result.market);
            require(token.isMarketPair(result.market), "provisioner: market registration");
        } else {
            require(result.market == expectedMarket, "provisioner: market mismatch");
        }
        require(result.tokenUsed > 0 && result.tokenUsed <= tokenAmount, "provisioner: token result");
        require(result.wethUsed > 0 && result.wethUsed <= msg.value, "provisioner: weth result");
        require(result.positionIdOrAmount > 0, "provisioner: empty position");

        uint256 tokenRefund = launchToken.balanceOf(address(this)) - tokenBefore;
        if (tokenRefund > 0) launchToken.safeTransfer(msg.sender, tokenRefund);
        uint256 wethRefund = wrapped.balanceOf(address(this)) - wethBefore;
        if (wethRefund > 0) {
            WETH.withdraw(wethRefund);
            (bool refunded,) = payable(msg.sender).call{value: wethRefund}("");
            require(refunded, "provisioner: refund failed");
        }
        require(launchToken.balanceOf(address(this)) == tokenBefore, "provisioner: token residue");
        require(wrapped.balanceOf(address(this)) == wethBefore, "provisioner: weth residue");

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
