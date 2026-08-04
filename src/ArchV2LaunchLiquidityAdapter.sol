// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {IArchLaunchLiquidityAdapter, IArchLaunchRegistry} from "./interfaces/IArchLaunchLiquidityAdapter.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "./interfaces/IUniswapV2.sol";

/// @title ArchV2LaunchLiquidityAdapter
/// @notice Seeds an exact-ratio canonical Uniswap V2 pair and moves the LP
///         result directly into the V2 locker or the permanent dead address.
///         It can only be called by the once-bound token factory or by a child
///         recorded in the once-bound launchpad registry.
contract ArchV2LaunchLiquidityAdapter is Ownable2Step, ReentrancyGuard, IArchLaunchLiquidityAdapter {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IUniswapV2Factory public immutable FACTORY;
    IUniswapV2Router02 public immutable ROUTER;
    IERC20 public immutable WETH;
    ArchLiquidityLocker public immutable LOCKER;

    address public tokenFactory;
    IArchLaunchRegistry public launchpad;
    bool public launchersBound;

    event LaunchersBound(address indexed tokenFactory, address indexed launchpad);
    event LiquiditySeeded(
        address indexed caller,
        address indexed token,
        address indexed pair,
        uint256 tokenAmount,
        uint256 wethAmount,
        uint256 liquidity,
        uint256 lockId,
        bool permanent
    );

    constructor(IUniswapV2Router02 router, ArchLiquidityLocker locker, address initialOwner) Ownable(initialOwner) {
        require(address(router).code.length > 0, "v2 adapter: invalid router");
        require(address(locker).code.length > 0, "v2 adapter: invalid locker");

        address factory = router.factory();
        address wrapped = router.WETH();
        require(factory.code.length > 0, "v2 adapter: invalid factory");
        require(wrapped.code.length > 0, "v2 adapter: invalid weth");
        require(address(locker.FACTORY()) == factory, "v2 adapter: factory mismatch");

        ROUTER = router;
        FACTORY = IUniswapV2Factory(factory);
        WETH = IERC20(wrapped);
        LOCKER = locker;
    }

    function weth() external view returns (address) {
        return address(WETH);
    }

    function validateSeedAmounts(uint256 tokenAmount, uint256 wethAmount) external pure {
        require(tokenAmount > 0 && wethAmount > 0, "v2 adapter: zero seed");
        require(tokenAmount <= type(uint112).max && wethAmount <= type(uint112).max, "v2 adapter: reserve overflow");
    }

    /// @notice Irreversibly binds the protocol entry points. At least one must
    ///         be set, and neither can be changed after this call.
    function bindLaunchers(address tokenFactory_, IArchLaunchRegistry launchpad_) external onlyOwner {
        require(!launchersBound, "v2 adapter: already bound");
        require(tokenFactory_ != address(0) || address(launchpad_) != address(0), "v2 adapter: no launcher");
        require(tokenFactory_ == address(0) || tokenFactory_.code.length > 0, "v2 adapter: invalid token factory");
        require(
            address(launchpad_) == address(0) || address(launchpad_).code.length > 0, "v2 adapter: invalid launchpad"
        );

        tokenFactory = tokenFactory_;
        launchpad = launchpad_;
        launchersBound = true;
        emit LaunchersBound(tokenFactory_, address(launchpad_));
    }

    function seed(SeedParams calldata p) external nonReentrant returns (SeedResult memory result) {
        require(_isAuthorized(msg.sender), "v2 adapter: unauthorized");
        require(p.token != address(0) && p.token != address(WETH), "v2 adapter: invalid token");
        require(p.tokenAmount > 0 && p.wethAmount > 0, "v2 adapter: zero seed");
        require(p.tokenAmount <= type(uint112).max && p.wethAmount <= type(uint112).max, "v2 adapter: reserve overflow");
        if (!p.permanent) {
            require(p.lockOwner != address(0), "v2 adapter: zero lock owner");
            require(p.unlockTime >= block.timestamp + LOCKER.MIN_DURATION(), "v2 adapter: lock too short");
        }

        IERC20 token = IERC20(p.token);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 wethBefore = WETH.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), p.tokenAmount);
        WETH.safeTransferFrom(msg.sender, address(this), p.wethAmount);
        require(token.balanceOf(address(this)) == tokenBefore + p.tokenAmount, "v2 adapter: token input mismatch");
        require(WETH.balanceOf(address(this)) == wethBefore + p.wethAmount, "v2 adapter: weth input mismatch");

        token.forceApprove(address(ROUTER), p.tokenAmount);
        WETH.forceApprove(address(ROUTER), p.wethAmount);
        address recipient = p.permanent ? DEAD : address(this);
        (uint256 tokenUsed, uint256 wethUsed, uint256 liquidity) = ROUTER.addLiquidity(
            p.token, address(WETH), p.tokenAmount, p.wethAmount, p.tokenAmount, p.wethAmount, recipient, block.timestamp
        );
        token.forceApprove(address(ROUTER), 0);
        WETH.forceApprove(address(ROUTER), 0);

        require(tokenUsed == p.tokenAmount && wethUsed == p.wethAmount, "v2 adapter: partial seed");
        require(liquidity > 0, "v2 adapter: zero liquidity");
        require(token.balanceOf(address(this)) == tokenBefore, "v2 adapter: token residue");
        require(WETH.balanceOf(address(this)) == wethBefore, "v2 adapter: weth residue");

        address pair = FACTORY.getPair(p.token, address(WETH));
        require(pair != address(0) && LOCKER.isCanonicalPair(pair), "v2 adapter: non-canonical pair");

        uint256 lockId = type(uint256).max;
        if (!p.permanent) {
            IERC20(pair).forceApprove(address(LOCKER), liquidity);
            lockId = LOCKER.lock(IERC20(pair), liquidity, p.unlockTime, p.lockOwner);
            IERC20(pair).forceApprove(address(LOCKER), 0);
            require(IERC20(pair).balanceOf(address(this)) == 0, "v2 adapter: lp residue");
        }

        result = SeedResult({
            market: pair,
            poolId: bytes32(uint256(uint160(pair))),
            positionManager: pair,
            positionIdOrAmount: liquidity,
            lockId: lockId,
            tokenUsed: tokenUsed,
            wethUsed: wethUsed
        });
        emit LiquiditySeeded(msg.sender, p.token, pair, p.tokenAmount, p.wethAmount, liquidity, lockId, p.permanent);
    }

    function _isAuthorized(address caller) private view returns (bool) {
        if (!launchersBound) return false;
        if (caller == tokenFactory) return true;
        IArchLaunchRegistry registry = launchpad;
        return address(registry) != address(0) && registry.isLaunch(caller);
    }
}
