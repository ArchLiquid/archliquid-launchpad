// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

/// @dev ABI-compatible representation of Uniswap V4's PoolKey. Currency is a
///      user-defined value type over address, so it is represented as address
///      at the ABI boundary.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IUniswapV4PoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory result);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function take(address currency, address to, uint256 amount) external;
}

interface IUniswapV4StateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IPermit2AllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Minimal PositionManager surface used by the locker and indexer. The
///      packed PositionInfo value is deliberately opaque: pool identity and
///      liquidity are obtained through the manager's public views.
interface IUniswapV4PositionManager {
    function poolManager() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function subscriber(uint256 tokenId) external view returns (address);
    function approve(address operator, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory poolKey, uint256 positionInfo);
}
