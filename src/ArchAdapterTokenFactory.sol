// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {IArchLaunchLiquidityAdapter} from "./interfaces/IArchLaunchLiquidityAdapter.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

/// @title ArchAdapterTokenFactory
/// @notice Versioned token factory whose launch-pool creation and custody are
///         delegated to one immutable, AMM-family-specific adapter.
contract ArchAdapterTokenFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint64 public constant MIN_LP_LOCK = 180 days;
    uint16 public constant MIN_LP_PCT = 10;

    uint256 public immutable FEE;
    address payable public immutable TREASURY;
    address public immutable KEEPER;
    IArchLaunchLiquidityAdapter public immutable LIQUIDITY_ADAPTER;
    ISwapRouter public immutable SWAP_ROUTER;
    IWETH9 public immutable WETH;
    uint24 public immutable TOKEN_POOL_FEE;
    uint24 public immutable STOCK_POOL_FEE;
    ArchStockRegistry public immutable STOCK_REGISTRY;

    struct TokenParams {
        string name;
        string symbol;
        uint256 totalSupply;
        uint16 taxBps;
        IERC20 stock;
        uint16 creatorFeeBps;
    }

    struct LiquidityParams {
        bool enabled;
        uint16 lpPct;
        uint24 poolFee;
        bool burnLp;
        uint64 lockDuration;
    }

    address[] public allTokens;
    uint256 private _deployNonce;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed market,
        bytes32 poolId,
        uint256 totalSupply,
        uint16 taxBps,
        bool lpBurned,
        uint256 positionIdOrAmount,
        uint256 lockId,
        uint256 tokenSeeded,
        uint256 wethSeeded
    );

    /// @dev Accept native ETH only from the immutable WETH contract while
    ///      unwrapping V4 rounding dust before refunding the creator.
    receive() external payable {
        require(msg.sender == address(WETH), "adapter factory: only weth");
    }

    constructor(
        uint256 fee,
        address payable treasury,
        address keeper,
        IArchLaunchLiquidityAdapter liquidityAdapter,
        ISwapRouter swapRouter,
        IWETH9 weth,
        uint24 tokenPoolFee,
        uint24 stockPoolFee,
        ArchStockRegistry stockRegistry
    ) {
        require(treasury != address(0), "adapter factory: zero treasury");
        require(keeper != address(0), "adapter factory: zero keeper");
        require(address(liquidityAdapter).code.length > 0, "adapter factory: invalid adapter");
        require(address(swapRouter).code.length > 0, "adapter factory: invalid router");
        require(address(weth).code.length > 0, "adapter factory: invalid weth");
        require(liquidityAdapter.weth() == address(weth), "adapter factory: weth mismatch");
        require(address(stockRegistry).code.length > 0, "adapter factory: invalid registry");

        FEE = fee;
        TREASURY = treasury;
        KEEPER = keeper;
        LIQUIDITY_ADAPTER = liquidityAdapter;
        SWAP_ROUTER = swapRouter;
        WETH = weth;
        TOKEN_POOL_FEE = tokenPoolFee;
        STOCK_POOL_FEE = stockPoolFee;
        STOCK_REGISTRY = stockRegistry;
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function createToken(TokenParams calldata t, LiquidityParams calldata liq)
        external
        payable
        nonReentrant
        returns (address tokenAddr)
    {
        require(msg.value >= FEE, "adapter factory: fee not covered");
        STOCK_REGISTRY.requireApproved(address(t.stock));
        uint256 seedEth = msg.value - FEE;

        if (liq.enabled) {
            require(seedEth > 0, "adapter factory: no seed eth");
            require(liq.lpPct >= MIN_LP_PCT && liq.lpPct <= 100, "adapter factory: lp pct out of range");
            require(liq.poolFee == TOKEN_POOL_FEE, "adapter factory: wrong pool fee");
            if (!liq.burnLp) require(liq.lockDuration >= MIN_LP_LOCK, "adapter factory: lock below minimum");
            LIQUIDITY_ADAPTER.validateSeedAmounts((t.totalSupply * liq.lpPct) / 100, seedEth);
        } else {
            require(seedEth == 0, "adapter factory: unexpected eth");
        }

        bytes32 salt = keccak256(
            abi.encode(
                msg.sender,
                blockhash(block.number - 1),
                block.number,
                block.timestamp,
                block.prevrandao,
                _deployNonce++,
                t.name,
                t.symbol
            )
        );
        ArchToken token = new ArchToken{salt: salt}(
            t.name,
            t.symbol,
            t.totalSupply,
            t.taxBps,
            t.stock,
            ArchToken.DexConfig({
                swapRouter: SWAP_ROUTER,
                weth: WETH,
                tokenPoolFee: TOKEN_POOL_FEE,
                stockPoolFee: STOCK_POOL_FEE,
                stockSwapExecutor: IArchStockSwapExecutor(STOCK_REGISTRY.stockSwapExecutor())
            }),
            TREASURY,
            KEEPER,
            t.creatorFeeBps,
            msg.sender
        );
        tokenAddr = address(token);

        token.setTaxExempt(address(LIQUIDITY_ADAPTER));
        token.setLiquidityProvisioner(LIQUIDITY_ADAPTER.liquidityProvisioner());
        token.setDividendExempt(address(this));
        token.setDividendExempt(tokenAddr);
        token.setDividendExempt(DEAD);
        token.setDividendExempt(address(LIQUIDITY_ADAPTER));

        IArchLaunchLiquidityAdapter.SeedResult memory seeded;
        if (liq.enabled) {
            uint256 lpTokens = (t.totalSupply * liq.lpPct) / 100;
            uint256 creatorTokens = t.totalSupply - lpTokens;
            if (creatorTokens > 0) IERC20(tokenAddr).safeTransfer(msg.sender, creatorTokens);

            WETH.deposit{value: seedEth}();
            IERC20(tokenAddr).forceApprove(address(LIQUIDITY_ADAPTER), lpTokens);
            IERC20(address(WETH)).forceApprove(address(LIQUIDITY_ADAPTER), seedEth);
            seeded = LIQUIDITY_ADAPTER.seed(
                IArchLaunchLiquidityAdapter.SeedParams({
                    token: tokenAddr,
                    tokenAmount: lpTokens,
                    wethAmount: seedEth,
                    lockOwner: msg.sender,
                    unlockTime: liq.burnLp ? 0 : uint64(block.timestamp) + liq.lockDuration,
                    permanent: liq.burnLp
                })
            );
            IERC20(tokenAddr).forceApprove(address(LIQUIDITY_ADAPTER), 0);
            IERC20(address(WETH)).forceApprove(address(LIQUIDITY_ADAPTER), 0);

            require(seeded.tokenUsed > 0 && seeded.wethUsed > 0, "adapter factory: empty seed");
            require(seeded.tokenUsed <= lpTokens && seeded.wethUsed <= seedEth, "adapter factory: seed overflow");
            token.addMarketPair(seeded.market);
            token.setDividendExempt(seeded.positionManager);

            uint256 tokenDust = lpTokens - seeded.tokenUsed;
            if (tokenDust > 0) IERC20(tokenAddr).safeTransfer(DEAD, tokenDust);
            uint256 wethDust = seedEth - seeded.wethUsed;
            if (wethDust > 0) {
                WETH.withdraw(wethDust);
                (bool refunded,) = payable(msg.sender).call{value: wethDust}("");
                require(refunded, "adapter factory: dust refund failed");
            }
        } else {
            IERC20(tokenAddr).safeTransfer(msg.sender, t.totalSupply);
        }

        token.finalizeWiring();
        allTokens.push(tokenAddr);

        (bool paid,) = TREASURY.call{value: FEE}("");
        require(paid, "adapter factory: fee transfer failed");

        emit TokenCreated(
            tokenAddr,
            msg.sender,
            seeded.market,
            seeded.poolId,
            t.totalSupply,
            t.taxBps,
            liq.enabled && liq.burnLp,
            seeded.positionIdOrAmount,
            seeded.lockId,
            seeded.tokenUsed,
            seeded.wethUsed
        );
    }
}
