// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchTokenDeployLib} from "./lib/ArchTokenDeployLib.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {IArchLaunchLiquidityAdapter} from "./interfaces/IArchLaunchLiquidityAdapter.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

/// @title ArchAdapterBondingCurve
/// @notice Constant-product fair launch that graduates through one immutable
///         AMM-family adapter when its exact real-ETH threshold is reached.
contract ArchAdapterBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 public constant TRADE_FEE_BPS = 100;

    struct Infra {
        address payable treasury;
        IArchLaunchLiquidityAdapter liquidityAdapter;
        ISwapRouter swapRouter;
        IWETH9 weth;
        uint24 tokenPoolFee;
        uint24 stockPoolFee;
        IArchStockSwapExecutor stockSwapExecutor;
        address keeper;
    }

    struct TokenConfig {
        string name;
        string symbol;
        uint256 totalSupply;
        uint16 taxBps;
        IERC20 stock;
        uint16 creatorFeeBps;
    }

    struct CurveConfig {
        uint16 curvePct;
        uint128 virtualEth;
        uint128 gradEth;
        uint24 poolFee;
    }

    address public immutable CREATOR;
    address payable public immutable TREASURY;
    IArchLaunchLiquidityAdapter public immutable LIQUIDITY_ADAPTER;
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

    uint256 public immutable CURVE_SUPPLY;
    uint256 public immutable LP_SUPPLY;
    uint256 public immutable K;
    uint128 public immutable GRAD_ETH;

    ArchToken public token;
    address public pair;
    bytes32 public poolId;
    uint256 public ethReserve;
    uint256 public tokenReserve;
    uint256 public realEthCollected;
    bool public graduated;

    event Bought(address indexed buyer, uint256 ethIn, uint256 fee, uint256 tokensOut);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 fee);
    event Graduated(
        address indexed market,
        bytes32 indexed poolId,
        uint256 wethSeeded,
        uint256 tokensSeeded,
        uint256 positionIdOrAmount
    );

    /// @dev Accept native ETH only from the immutable WETH contract while
    ///      unwrapping V4 rounding dust after graduation.
    receive() external payable {
        require(msg.sender == address(WETH), "adapter curve: only weth");
    }

    constructor(address creator, Infra memory infra, TokenConfig memory t, CurveConfig memory c) {
        require(creator != address(0), "adapter curve: zero creator");
        require(infra.treasury != address(0), "adapter curve: zero treasury");
        require(address(infra.liquidityAdapter).code.length > 0, "adapter curve: invalid adapter");
        require(address(infra.swapRouter).code.length > 0, "adapter curve: invalid router");
        require(address(infra.weth).code.length > 0, "adapter curve: invalid weth");
        require(infra.liquidityAdapter.weth() == address(infra.weth), "adapter curve: weth mismatch");
        require(infra.keeper != address(0), "adapter curve: zero keeper");
        require(address(infra.stockSwapExecutor) != address(0), "adapter curve: zero executor");
        require(t.totalSupply > 0, "adapter curve: zero supply");
        require(t.taxBps >= 100 && t.taxBps <= 500, "adapter curve: tax out of range");
        require(t.creatorFeeBps <= 100 && uint256(t.taxBps) + t.creatorFeeBps <= 600, "adapter curve: fee out of range");
        require(address(t.stock) != address(0), "adapter curve: zero stock");
        require(c.curvePct >= 50 && c.curvePct < 100, "adapter curve: bad curve pct");
        require(c.virtualEth > 0 && c.gradEth > 0, "adapter curve: bad params");
        require(uint256(c.gradEth) <= 9 * uint256(c.virtualEth), "adapter curve: grad unreachable");
        require(c.poolFee == infra.tokenPoolFee, "adapter curve: wrong pool fee");

        CREATOR = creator;
        TREASURY = infra.treasury;
        LIQUIDITY_ADAPTER = infra.liquidityAdapter;
        SWAP_ROUTER = infra.swapRouter;
        WETH = infra.weth;
        POOL_FEE = infra.tokenPoolFee;
        STOCK_POOL_FEE = infra.stockPoolFee;
        KEEPER = infra.keeper;

        tokenName = t.name;
        tokenSymbol = t.symbol;
        TOTAL_SUPPLY = t.totalSupply;
        TAX_BPS = t.taxBps;
        CREATOR_FEE_BPS = t.creatorFeeBps;
        STOCK = t.stock;

        uint256 curveSupply = (t.totalSupply * c.curvePct) / 100;
        require(curveSupply > 0, "adapter curve: curve supply zero");
        CURVE_SUPPLY = curveSupply;
        LP_SUPPLY = t.totalSupply - curveSupply;
        GRAD_ETH = c.gradEth;
        ethReserve = c.virtualEth;
        tokenReserve = curveSupply;
        K = uint256(c.virtualEth) * curveSupply;

        uint256 tokensAtGraduation = Math.ceilDiv(K, uint256(c.virtualEth) + c.gradEth) + LP_SUPPLY;
        infra.liquidityAdapter.validateSeedAmounts(tokensAtGraduation, c.gradEth);

        token = ArchTokenDeployLib.deploy(
            t.name,
            t.symbol,
            t.totalSupply,
            t.taxBps,
            t.stock,
            ArchToken.DexConfig({
                swapRouter: infra.swapRouter,
                weth: infra.weth,
                tokenPoolFee: infra.tokenPoolFee,
                stockPoolFee: infra.stockPoolFee,
                stockSwapExecutor: infra.stockSwapExecutor
            }),
            infra.treasury,
            infra.keeper,
            t.creatorFeeBps,
            creator,
            bytes32(0)
        );
    }

    function quoteBuy(uint256 ethIn) public view returns (uint256 tokensOut, uint256 fee) {
        fee = (ethIn * TRADE_FEE_BPS) / 10_000;
        uint256 net = ethIn - fee;
        if (realEthCollected + net > GRAD_ETH) return (0, fee);
        uint256 newTokenReserve = Math.ceilDiv(K, ethReserve + net);
        tokensOut = tokenReserve - newTokenReserve;
    }

    function quoteSell(uint256 tokensIn) public view returns (uint256 ethOut, uint256 fee) {
        uint256 newEthReserve = Math.ceilDiv(K, tokenReserve + tokensIn);
        uint256 grossEth = ethReserve - newEthReserve;
        fee = (grossEth * TRADE_FEE_BPS) / 10_000;
        ethOut = grossEth - fee;
    }

    /// @notice Exact gross ETH that reaches the remaining graduation target
    ///         after the 1% floor-rounded trade fee. Frontends can use this to
    ///         avoid an overshooting transaction near graduation.
    function graduationBuyAmount() external view returns (uint256) {
        uint256 remaining = uint256(GRAD_ETH) - realEthCollected;
        return remaining == 0 ? 0 : remaining + (remaining / 99);
    }

    function buy(uint256 minTokensOut) external payable nonReentrant {
        require(!graduated, "adapter curve: graduated");
        require(msg.value > 0, "adapter curve: zero value");
        uint256 fee = (msg.value * TRADE_FEE_BPS) / 10_000;
        uint256 net = msg.value - fee;
        require(realEthCollected + net <= GRAD_ETH, "adapter curve: exceeds graduation");
        uint256 newEthReserve = ethReserve + net;
        uint256 newTokenReserve = Math.ceilDiv(K, newEthReserve);
        uint256 tokensOut = tokenReserve - newTokenReserve;
        require(tokensOut >= minTokensOut && tokensOut > 0, "adapter curve: slippage");

        ethReserve = newEthReserve;
        tokenReserve = newTokenReserve;
        realEthCollected += net;
        (bool paid,) = TREASURY.call{value: fee}("");
        require(paid, "adapter curve: fee send failed");
        IERC20(address(token)).safeTransfer(msg.sender, tokensOut);
        emit Bought(msg.sender, msg.value, fee, tokensOut);
        if (realEthCollected == GRAD_ETH) _graduate();
    }

    function sell(uint256 tokensIn, uint256 minEthOut) external nonReentrant {
        require(!graduated, "adapter curve: graduated");
        require(tokensIn > 0, "adapter curve: zero tokens");
        uint256 newTokenReserve = tokenReserve + tokensIn;
        uint256 newEthReserve = Math.ceilDiv(K, newTokenReserve);
        uint256 grossEth = ethReserve - newEthReserve;
        uint256 fee = (grossEth * TRADE_FEE_BPS) / 10_000;
        uint256 ethOut = grossEth - fee;
        require(ethOut >= minEthOut && ethOut > 0, "adapter curve: slippage");

        ethReserve = newEthReserve;
        tokenReserve = newTokenReserve;
        realEthCollected -= grossEth;
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokensIn);
        (bool feePaid,) = TREASURY.call{value: fee}("");
        require(feePaid, "adapter curve: fee send failed");
        (bool paid,) = payable(msg.sender).call{value: ethOut}("");
        require(paid, "adapter curve: eth send failed");
        emit Sold(msg.sender, tokensIn, ethOut, fee);
    }

    function _graduate() private {
        ArchToken launched = token;
        uint256 tokensToLp = launched.balanceOf(address(this));
        uint256 ethToLp = realEthCollected;
        WETH.deposit{value: ethToLp}();
        launched.approve(address(LIQUIDITY_ADAPTER), tokensToLp);
        IERC20(address(WETH)).forceApprove(address(LIQUIDITY_ADAPTER), ethToLp);
        IArchLaunchLiquidityAdapter.SeedResult memory seeded = LIQUIDITY_ADAPTER.seed(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(launched),
                tokenAmount: tokensToLp,
                wethAmount: ethToLp,
                lockOwner: address(0),
                unlockTime: 0,
                permanent: true
            })
        );
        launched.approve(address(LIQUIDITY_ADAPTER), 0);
        IERC20(address(WETH)).forceApprove(address(LIQUIDITY_ADAPTER), 0);
        require(seeded.tokenUsed > 0 && seeded.wethUsed > 0, "adapter curve: empty seed");
        require(seeded.tokenUsed <= tokensToLp && seeded.wethUsed <= ethToLp, "adapter curve: seed overflow");

        graduated = true;
        pair = seeded.market;
        poolId = seeded.poolId;
        launched.addMarketPair(seeded.market);
        launched.setDividendExempt(address(this));
        launched.setDividendExempt(address(launched));
        launched.setDividendExempt(DEAD);
        launched.setDividendExempt(address(LIQUIDITY_ADAPTER));
        launched.setDividendExempt(seeded.positionManager);

        uint256 tokenDust = tokensToLp - seeded.tokenUsed;
        if (tokenDust > 0) IERC20(address(launched)).safeTransfer(DEAD, tokenDust);
        uint256 wethDust = ethToLp - seeded.wethUsed;
        if (wethDust > 0) {
            WETH.withdraw(wethDust);
            (bool paid,) = TREASURY.call{value: wethDust}("");
            require(paid, "adapter curve: dust send failed");
        }

        launched.finalizeWiring();
        emit Graduated(seeded.market, seeded.poolId, seeded.wethUsed, seeded.tokenUsed, seeded.positionIdOrAmount);
    }
}
