// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {IArchLaunchLiquidityAdapter, IArchLaunchRegistry} from "./interfaces/IArchLaunchLiquidityAdapter.sol";
import {
    IPermit2AllowanceTransfer,
    IUniswapV4PoolManager,
    IUniswapV4PositionManager,
    IUniswapV4StateView,
    PoolKey
} from "./interfaces/IUniswapV4.sol";
import {UniV3} from "@archliquid/core/lib/UniV3.sol";

/// @title ArchV4LaunchLiquidityAdapter
/// @notice Initializes one hookless, static-fee V4 pool and mints a full-range
///         position through the canonical PositionManager. The position moves
///         directly into ArchLiquid custody or to the permanent dead address.
contract ArchV4LaunchLiquidityAdapter is Ownable2Step, ReentrancyGuard, IArchLaunchLiquidityAdapter {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint24 public constant POOL_FEE = 3000;
    int24 public constant TICK_SPACING = 60;
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 887220;
    uint160 private constant SQRT_LOWER_X96 = 4306310044;
    uint160 private constant SQRT_UPPER_X96 = 1457652066949847389937902910258958406565750968363;
    uint256 private constant Q96 = 1 << 96;
    uint8 private constant MINT_POSITION = 0x02;
    uint8 private constant SETTLE_PAIR = 0x0d;

    IUniswapV4PositionManager public immutable POSITION_MANAGER;
    IUniswapV4PoolManager public immutable POOL_MANAGER;
    IUniswapV4StateView public immutable STATE_VIEW;
    IPermit2AllowanceTransfer public immutable PERMIT2;
    IERC20 public immutable WETH;
    ArchV4PositionLocker public immutable LOCKER;

    address public tokenFactory;
    IArchLaunchRegistry public launchpad;
    address public liquidityProvisioner;
    bool public launchersBound;

    event LaunchersBound(address indexed tokenFactory, address indexed launchpad);
    event LiquidityProvisionerBound(address indexed provisioner);
    event LiquiditySeeded(
        address indexed caller,
        address indexed token,
        bytes32 indexed poolId,
        uint256 tokenId,
        uint256 tokenUsed,
        uint256 wethUsed,
        uint256 lockId,
        bool permanent
    );

    constructor(
        IUniswapV4PositionManager positionManager,
        IUniswapV4StateView stateView,
        IPermit2AllowanceTransfer permit2,
        IERC20 weth_,
        ArchV4PositionLocker locker,
        address initialOwner
    ) Ownable(initialOwner) {
        require(address(positionManager).code.length > 0, "v4 adapter: invalid manager");
        require(address(stateView).code.length > 0, "v4 adapter: invalid state view");
        require(address(permit2).code.length > 0, "v4 adapter: invalid permit2");
        require(address(weth_).code.length > 0, "v4 adapter: invalid weth");
        require(address(locker).code.length > 0, "v4 adapter: invalid locker");
        require(address(locker.POSITION_MANAGER()) == address(positionManager), "v4 adapter: manager mismatch");

        address poolManager = positionManager.poolManager();
        require(poolManager.code.length > 0 && locker.POOL_MANAGER() == poolManager, "v4 adapter: pool mismatch");

        POSITION_MANAGER = positionManager;
        POOL_MANAGER = IUniswapV4PoolManager(poolManager);
        STATE_VIEW = stateView;
        PERMIT2 = permit2;
        WETH = weth_;
        LOCKER = locker;
    }

    function weth() external view returns (address) {
        return address(WETH);
    }

    function validateSeedAmounts(uint256 tokenAmount, uint256 wethAmount) external pure {
        require(tokenAmount > 0 && wethAmount > 0, "v4 adapter: zero seed");
        require(tokenAmount <= type(uint128).max && wethAmount <= type(uint128).max, "v4 adapter: seed too large");
        UniV3.sqrtPriceX96(tokenAmount, wethAmount);
        UniV3.sqrtPriceX96(wethAmount, tokenAmount);
    }

    function bindLiquidityProvisioner(address provisioner) external onlyOwner {
        require(!launchersBound, "v4 adapter: launchers bound");
        require(liquidityProvisioner == address(0), "v4 adapter: provisioner set");
        require(provisioner.code.length > 0, "v4 adapter: invalid provisioner");
        liquidityProvisioner = provisioner;
        emit LiquidityProvisionerBound(provisioner);
    }

    function bindLaunchers(address tokenFactory_, IArchLaunchRegistry launchpad_) external onlyOwner {
        require(!launchersBound, "v4 adapter: already bound");
        require(tokenFactory_ != address(0) || address(launchpad_) != address(0), "v4 adapter: no launcher");
        require(tokenFactory_ == address(0) || tokenFactory_.code.length > 0, "v4 adapter: invalid token factory");
        require(
            address(launchpad_) == address(0) || address(launchpad_).code.length > 0, "v4 adapter: invalid launchpad"
        );

        tokenFactory = tokenFactory_;
        launchpad = launchpad_;
        launchersBound = true;
        emit LaunchersBound(tokenFactory_, address(launchpad_));
    }

    function seed(SeedParams calldata p) external nonReentrant returns (SeedResult memory result) {
        require(_isAuthorized(msg.sender), "v4 adapter: unauthorized");
        require(p.token != address(0) && p.token != address(WETH), "v4 adapter: invalid token");
        require(p.tokenAmount > 0 && p.wethAmount > 0, "v4 adapter: zero seed");
        require(p.tokenAmount <= type(uint128).max && p.wethAmount <= type(uint128).max, "v4 adapter: seed too large");
        if (!p.permanent) {
            require(p.lockOwner != address(0), "v4 adapter: zero lock owner");
            require(p.unlockTime >= block.timestamp + LOCKER.MIN_DURATION(), "v4 adapter: lock too short");
        }

        IERC20 token = IERC20(p.token);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 wethBefore = WETH.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), p.tokenAmount);
        WETH.safeTransferFrom(msg.sender, address(this), p.wethAmount);
        require(token.balanceOf(address(this)) == tokenBefore + p.tokenAmount, "v4 adapter: token input mismatch");
        require(WETH.balanceOf(address(this)) == wethBefore + p.wethAmount, "v4 adapter: weth input mismatch");

        (PoolKey memory key, uint256 amount0, uint256 amount1) = _poolKeyAndAmounts(p);
        uint160 sqrtPriceX96 = UniV3.sqrtPriceX96(amount0, amount1);
        bytes32 poolId = keccak256(abi.encode(key));

        // initialize() reverts when a pool already exists. Existing pools are
        // accepted only when StateView proves the exact intended seed price.
        try POOL_MANAGER.initialize(key, sqrtPriceX96) {} catch {}
        (uint160 actualSqrt,,,) = STATE_VIEW.getSlot0(poolId);
        require(actualSqrt == sqrtPriceX96, "v4 adapter: hostile pool price");

        uint128 liquidity = _liquidityForAmounts(sqrtPriceX96, amount0, amount1);
        require(liquidity > 0, "v4 adapter: zero liquidity");
        uint256 tokenId = POSITION_MANAGER.nextTokenId();
        address positionOwner = p.permanent ? DEAD : address(this);

        token.forceApprove(address(PERMIT2), p.tokenAmount);
        WETH.forceApprove(address(PERMIT2), p.wethAmount);
        PERMIT2.approve(p.token, address(POSITION_MANAGER), uint160(p.tokenAmount), uint48(block.timestamp));
        PERMIT2.approve(address(WETH), address(POSITION_MANAGER), uint160(p.wethAmount), uint48(block.timestamp));

        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            TICK_LOWER,
            TICK_UPPER,
            uint256(liquidity),
            uint128(amount0),
            uint128(amount1),
            positionOwner,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        PERMIT2.approve(p.token, address(POSITION_MANAGER), 0, 0);
        PERMIT2.approve(address(WETH), address(POSITION_MANAGER), 0, 0);
        token.forceApprove(address(PERMIT2), 0);
        WETH.forceApprove(address(PERMIT2), 0);

        require(POSITION_MANAGER.ownerOf(tokenId) == positionOwner, "v4 adapter: position owner mismatch");
        require(POSITION_MANAGER.getPositionLiquidity(tokenId) == liquidity, "v4 adapter: liquidity mismatch");

        uint256 tokenRemaining = token.balanceOf(address(this)) - tokenBefore;
        uint256 wethRemaining = WETH.balanceOf(address(this)) - wethBefore;
        uint256 tokenUsed = p.tokenAmount - tokenRemaining;
        uint256 wethUsed = p.wethAmount - wethRemaining;
        require(tokenUsed > 0 && wethUsed > 0, "v4 adapter: empty side");
        if (tokenRemaining > 0) token.safeTransfer(msg.sender, tokenRemaining);
        if (wethRemaining > 0) WETH.safeTransfer(msg.sender, wethRemaining);
        require(token.balanceOf(address(this)) == tokenBefore, "v4 adapter: token residue");
        require(WETH.balanceOf(address(this)) == wethBefore, "v4 adapter: weth residue");

        uint256 lockId = type(uint256).max;
        if (!p.permanent) {
            POSITION_MANAGER.approve(address(LOCKER), tokenId);
            lockId = LOCKER.lock(tokenId, p.unlockTime, p.lockOwner);
            require(POSITION_MANAGER.ownerOf(tokenId) == address(LOCKER), "v4 adapter: lock failed");
        }

        result = SeedResult({
            market: address(POOL_MANAGER),
            poolId: poolId,
            positionManager: address(POSITION_MANAGER),
            positionIdOrAmount: tokenId,
            lockId: lockId,
            tokenUsed: tokenUsed,
            wethUsed: wethUsed
        });
        emit LiquiditySeeded(msg.sender, p.token, poolId, tokenId, tokenUsed, wethUsed, lockId, p.permanent);
    }

    function _poolKeyAndAmounts(SeedParams calldata p)
        private
        view
        returns (PoolKey memory key, uint256 amount0, uint256 amount1)
    {
        bool tokenIs0 = p.token < address(WETH);
        key = PoolKey({
            currency0: tokenIs0 ? p.token : address(WETH),
            currency1: tokenIs0 ? address(WETH) : p.token,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(0)
        });
        (amount0, amount1) = tokenIs0 ? (p.tokenAmount, p.wethAmount) : (p.wethAmount, p.tokenAmount);
    }

    function _liquidityForAmounts(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint128)
    {
        uint256 intermediate = Math.mulDiv(sqrtPriceX96, SQRT_UPPER_X96, Q96);
        uint256 liquidity0 = Math.mulDiv(amount0, intermediate, SQRT_UPPER_X96 - sqrtPriceX96);
        uint256 liquidity1 = Math.mulDiv(amount1, Q96, sqrtPriceX96 - SQRT_LOWER_X96);
        uint256 liquidity = Math.min(liquidity0, liquidity1);
        require(liquidity <= type(uint128).max, "v4 adapter: liquidity overflow");
        return uint128(liquidity);
    }

    function _isAuthorized(address caller) private view returns (bool) {
        if (!launchersBound) return false;
        if (caller == liquidityProvisioner) return true;
        if (caller == tokenFactory) return true;
        IArchLaunchRegistry registry = launchpad;
        return address(registry) != address(0) && registry.isLaunch(caller);
    }
}
