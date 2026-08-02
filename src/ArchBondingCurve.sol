// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {
    INonfungiblePositionManager,
    ISwapRouter,
    IWETH9,
    IUniswapV3PoolMinimal
} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {ArchTokenDeployLib} from "./lib/ArchTokenDeployLib.sol";
import {UniV3} from "@archliquid/core/lib/UniV3.sol";

/// @title ArchBondingCurve
/// @notice Fair-launch bonding curve for an RWA distributor token. No presale,
///         no team allocation. Tokens are bought and sold against a
///         constant-product virtual-reserve curve with a flat protocol trade
///         fee. When the real ETH collected reaches the graduation threshold,
///         all collected ETH and all remaining tokens are deposited into a
///         Uniswap pool and the LP is burned forever, then the tax + stock
///         distribution go live on the pair. Rounding always favors the
///         contract so the curve can never be drained by rounding.
contract ArchBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 public constant TRADE_FEE_BPS = 100; // 1%

    struct Infra {
        address payable treasury;
        INonfungiblePositionManager nfpm;
        ISwapRouter swapRouter;
        IWETH9 weth;
        uint24 stockPoolFee; // fee tier of the stock/WETH pools
        IArchStockSwapExecutor stockSwapExecutor;
        address keeper;
    }

    struct TokenConfig {
        string name;
        string symbol;
        uint256 totalSupply;
        uint16 taxBps;
        IERC20 stock;
        uint16 creatorFeeBps; // stacked on top of the tax, 0..ArchToken.MAX_CREATOR_FEE_BPS
    }

    struct CurveConfig {
        uint16 curvePct; // % of supply sold on the curve; rest seeds graduation LP
        uint128 virtualEth; // virtual ETH reserve offset (sets the start price)
        uint128 gradEth; // real ETH collected that triggers graduation
        uint24 poolFee; // V3 fee tier of the graduation pool
    }

    address public immutable CREATOR;
    address payable public immutable TREASURY;
    INonfungiblePositionManager public immutable NFPM;
    ISwapRouter public immutable SWAP_ROUTER;
    IWETH9 public immutable WETH;
    uint24 public immutable POOL_FEE;
    uint24 public immutable STOCK_POOL_FEE;
    address public immutable KEEPER;

    string public tokenName;
    string public tokenSymbol;
    uint256 public immutable TOTAL_SUPPLY;
    uint16 public immutable TAX_BPS;
    uint16 public immutable CREATOR_FEE_BPS;
    IERC20 public immutable STOCK;

    uint256 public immutable CURVE_SUPPLY; // tokens available on the curve
    uint256 public immutable LP_SUPPLY; // tokens reserved for graduation liquidity
    uint256 public immutable K; // constant product: virtualEth * CURVE_SUPPLY
    uint128 public immutable GRAD_ETH;

    ArchToken public token;
    address public pair;
    uint256 public ethReserve; // virtual + real ETH on the curve
    uint256 public tokenReserve; // tokens still on the curve
    uint256 public realEthCollected; // real ETH held (buys - sells - fees)
    bool public graduated;

    event Bought(address indexed buyer, uint256 ethIn, uint256 fee, uint256 tokensOut);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 fee);
    event Graduated(address indexed pair, uint256 ethToLp, uint256 tokensToLp);

    constructor(address creator, Infra memory infra, TokenConfig memory t, CurveConfig memory c) {
        require(creator != address(0), "curve: zero creator");
        require(infra.treasury != address(0), "curve: zero treasury");
        require(infra.keeper != address(0), "curve: zero keeper");
        require(address(infra.stockSwapExecutor) != address(0), "curve: zero executor");
        require(t.totalSupply > 0, "curve: zero supply");
        require(t.taxBps >= 100 && t.taxBps <= 500, "curve: tax out of range");
        // Mirror ArchToken.MAX_CREATOR_FEE_BPS (100) / MAX_TOTAL_BPS (600).
        require(t.creatorFeeBps <= 100, "curve: creator fee too high");
        require(uint256(t.taxBps) + t.creatorFeeBps <= 600, "curve: total fee too high");
        require(address(t.stock) != address(0), "curve: zero stock");
        require(c.curvePct >= 50 && c.curvePct < 100, "curve: bad curve pct");
        require(c.virtualEth > 0 && c.gradEth > 0, "curve: bad curve params");
        // graduation must be reachable within the curve's productive range
        // (real ETH ~= 9x virtualEth by the time ~90% of the curve is sold),
        // so a curve can never be configured to collect ETH yet never graduate
        require(uint256(c.gradEth) <= 9 * uint256(c.virtualEth), "curve: grad unreachable");
        require(c.poolFee == 100 || c.poolFee == 500 || c.poolFee == 3000 || c.poolFee == 10000, "curve: bad pool fee");

        CREATOR = creator;
        TREASURY = infra.treasury;
        NFPM = infra.nfpm;
        SWAP_ROUTER = infra.swapRouter;
        WETH = infra.weth;
        POOL_FEE = c.poolFee;
        STOCK_POOL_FEE = infra.stockPoolFee;
        KEEPER = infra.keeper;

        tokenName = t.name;
        tokenSymbol = t.symbol;
        TOTAL_SUPPLY = t.totalSupply;
        TAX_BPS = t.taxBps;
        CREATOR_FEE_BPS = t.creatorFeeBps;
        STOCK = t.stock;

        uint256 curveSupply = (t.totalSupply * c.curvePct) / 100;
        require(curveSupply > 0, "curve: curve supply zero");
        CURVE_SUPPLY = curveSupply;
        LP_SUPPLY = t.totalSupply - curveSupply;
        GRAD_ETH = c.gradEth;

        ethReserve = c.virtualEth;
        tokenReserve = curveSupply;
        K = uint256(c.virtualEth) * curveSupply;

        // deploy the token; the curve holds the full supply and is the token's
        // factory/wirer. Distribution exemptions and the market pair are set at
        // graduation, when trading actually begins on Uniswap.
        ArchToken tok = ArchTokenDeployLib.deploy(
            t.name,
            t.symbol,
            t.totalSupply,
            t.taxBps,
            t.stock,
            ArchToken.DexConfig({
                swapRouter: infra.swapRouter,
                weth: infra.weth,
                tokenPoolFee: c.poolFee,
                stockPoolFee: infra.stockPoolFee,
                stockSwapExecutor: infra.stockSwapExecutor
            }),
            infra.treasury,
            infra.keeper,
            CREATOR_FEE_BPS,
            CREATOR,
            bytes32(0)
        );
        token = tok;
    }

    /* ── quotes ──────────────────────────────────────────────────── */

    function quoteBuy(uint256 ethIn) public view returns (uint256 tokensOut, uint256 fee) {
        fee = (ethIn * TRADE_FEE_BPS) / 10_000;
        uint256 e = ethIn - fee;
        // round the new token reserve UP so tokensOut is rounded down
        uint256 newTokenReserve = Math.ceilDiv(K, ethReserve + e);
        tokensOut = tokenReserve - newTokenReserve;
    }

    function quoteSell(uint256 tokensIn) public view returns (uint256 ethOut, uint256 fee) {
        uint256 newEthReserve = Math.ceilDiv(K, tokenReserve + tokensIn);
        uint256 grossEth = ethReserve - newEthReserve;
        fee = (grossEth * TRADE_FEE_BPS) / 10_000;
        ethOut = grossEth - fee;
    }

    /* ── trade ───────────────────────────────────────────────────── */

    function buy(uint256 minTokensOut) external payable nonReentrant {
        require(!graduated, "curve: graduated");
        require(msg.value > 0, "curve: zero value");

        uint256 fee = (msg.value * TRADE_FEE_BPS) / 10_000;
        uint256 e = msg.value - fee;
        uint256 newEthReserve = ethReserve + e;
        // round new token reserve up => tokensOut rounded down (favors curve)
        uint256 newTokenReserve = Math.ceilDiv(K, newEthReserve);
        uint256 tokensOut = tokenReserve - newTokenReserve;
        require(tokensOut >= minTokensOut, "curve: slippage");
        require(tokensOut > 0, "curve: nothing out");

        ethReserve = newEthReserve;
        tokenReserve = newTokenReserve;
        realEthCollected += e;

        (bool okFee,) = TREASURY.call{value: fee}("");
        require(okFee, "curve: fee send failed");
        IERC20(address(token)).safeTransfer(msg.sender, tokensOut);
        emit Bought(msg.sender, msg.value, fee, tokensOut);

        if (realEthCollected >= GRAD_ETH) _graduate();
    }

    function sell(uint256 tokensIn, uint256 minEthOut) external nonReentrant {
        require(!graduated, "curve: graduated");
        require(tokensIn > 0, "curve: zero tokens");

        // round new eth reserve up => grossEth rounded down (favors curve)
        uint256 newTokenReserve = tokenReserve + tokensIn;
        uint256 newEthReserve = Math.ceilDiv(K, newTokenReserve);
        uint256 grossEth = ethReserve - newEthReserve;
        uint256 fee = (grossEth * TRADE_FEE_BPS) / 10_000;
        uint256 ethOut = grossEth - fee;
        require(ethOut >= minEthOut, "curve: slippage");
        require(ethOut > 0, "curve: nothing out");

        ethReserve = newEthReserve;
        tokenReserve = newTokenReserve;
        realEthCollected -= grossEth;

        // pull the sold tokens back onto the curve (curve is tax-exempt)
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokensIn);

        (bool okFee,) = TREASURY.call{value: fee}("");
        require(okFee, "curve: fee send failed");
        (bool okOut,) = payable(msg.sender).call{value: ethOut}("");
        require(okOut, "curve: eth send failed");
        emit Sold(msg.sender, tokensIn, ethOut, fee);
    }

    /* ── graduation ──────────────────────────────────────────────── */

    function _graduate() private {
        graduated = true;
        ArchToken t = token;

        // all remaining tokens (curve leftover + reserved LP) and all collected
        // ETH seed a full-range V3 position whose NFT is minted to the dead
        // address: liquidity is permanent
        uint256 tokensToLp = t.balanceOf(address(this));
        uint256 ethToLp = realEthCollected;
        WETH.deposit{value: ethToLp}();

        (address token0, address token1) = UniV3.sortTokens(address(t), address(WETH));
        (uint256 amount0, uint256 amount1) = token0 == address(t) ? (tokensToLp, ethToLp) : (ethToLp, tokensToLp);

        // createAndInitialize...() is a no-op on a pre-existing pool, so verify
        // the pool holds our seed price. A griefer can front-run pool creation
        // at a hostile price for zero liquidity; if so, revert (the triggering
        // buy reverts and the curve stays pre-graduation, where sellers keep
        // their curve exit, rather than seeding an empty, mispriced pool).
        uint160 sqrtPriceX96 = UniV3.sqrtPriceX96(amount0, amount1);
        address p = NFPM.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);
        (uint160 gotSqrt,,,,,,) = IUniswapV3PoolMinimal(p).slot0();
        require(gotSqrt == sqrtPriceX96, "curve: pool pre-initialized");
        pair = p;

        // wire the pool as a taxed market pair and exclude infrastructure /
        // custody from dividends before liquidity moves
        t.addMarketPair(p);
        t.setDividendExempt(address(this));
        t.setDividendExempt(address(t));
        t.setDividendExempt(DEAD);

        t.approve(address(NFPM), tokensToLp);
        IERC20(address(WETH)).forceApprove(address(NFPM), ethToLp);
        (int24 tickLower, int24 tickUpper) = UniV3.fullRangeTicks(POOL_FEE);
        NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: DEAD,
                deadline: block.timestamp
            })
        );

        t.finalizeWiring();
        emit Graduated(p, ethToLp, tokensToLp);
    }
}
