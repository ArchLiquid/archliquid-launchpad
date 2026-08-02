// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {
    INonfungiblePositionManager,
    ISwapRouter,
    IWETH9,
    IUniswapV3PoolMinimal
} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {UniV3} from "@archliquid/core/lib/UniV3.sol";
import {ArchTokenDeployLib} from "./lib/ArchTokenDeployLib.sol";

/// @title ArchPresale
/// @notice One fixed-price presale of an RWA distributor token. The trust
///         guarantee: every contributed wei, minus the flat protocol raise
///         fee, becomes locked liquidity at finalize. The team receives no
///         ETH from the raise, only tokens vested (cliff + linear) inside this
///         contract. If the soft cap is missed, contributors take a full
///         refund. There is no owner and no path for anyone to move escrowed
///         ETH except refunds or the finalize flow.
contract ArchPresale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Infra {
        address payable treasury;
        ArchV3PositionLocker locker;
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

    struct SaleConfig {
        uint128 softCap;
        uint128 hardCap;
        uint64 start;
        uint64 end;
        uint128 perWalletCap; // 0 = no per-wallet cap
        uint16 salePct; // % of supply sold to contributors
        uint16 lpPct; // % of supply paired into locked liquidity
        uint24 poolFee; // V3 fee tier of the launch pool (100/500/3000/10000)
        uint64 lpLockDuration; // >= locker MIN_DURATION
        uint64 teamCliff; // team vesting cliff timestamp
        uint64 teamEnd; // team vesting end timestamp
    }

    uint16 public constant RAISE_FEE_BPS = 300; // 3%

    address public immutable CREATOR;
    address payable public immutable TREASURY;
    ArchV3PositionLocker public immutable LOCKER;
    INonfungiblePositionManager public immutable NFPM;
    ISwapRouter public immutable SWAP_ROUTER;
    IWETH9 public immutable WETH;
    uint24 public immutable POOL_FEE;
    uint24 public immutable STOCK_POOL_FEE;
    IArchStockSwapExecutor public immutable STOCK_SWAP_EXECUTOR;
    address public immutable KEEPER;

    // token
    string public tokenName;
    string public tokenSymbol;
    uint256 public immutable TOTAL_SUPPLY;
    uint16 public immutable TAX_BPS;
    uint16 public immutable CREATOR_FEE_BPS;
    IERC20 public immutable STOCK;

    // sale
    uint128 public immutable SOFT_CAP;
    uint128 public immutable HARD_CAP;
    uint64 public immutable START;
    uint64 public immutable END;
    uint128 public immutable PER_WALLET_CAP;
    uint256 public immutable TOKENS_PER_ETH; // token units per 1e18 wei
    uint256 public immutable SALE_TOKENS;
    uint256 public immutable LP_TOKENS;
    uint256 public immutable TEAM_TOKENS;
    uint64 public immutable LP_LOCK_DURATION;
    uint64 public immutable TEAM_CLIFF;
    uint64 public immutable TEAM_END;

    uint256 public totalRaised;
    mapping(address => uint256) public contributed;
    mapping(address => bool) public claimed;
    uint256 public teamReleased;
    // accumulated over every contribution; seeds the token's CREATE2 salt so
    // the launch pool address cannot be pre-computed (and thus pre-initialized)
    // by a griefer before finalize
    bytes32 private _entropy;

    bool public finalized;
    bool public canceled; // soft cap missed after end
    ArchToken public token;
    address public pair;

    event Contributed(address indexed who, uint256 amount, uint256 total);
    event Finalized(address indexed token, address pair, uint256 raised, uint256 lpEth, uint256 lockId);
    event Canceled();
    event Claimed(address indexed who, uint256 tokenAmount);
    event Refunded(address indexed who, uint256 amount);
    event TeamClaimed(uint256 tokenAmount);

    constructor(address creator, Infra memory infra, TokenConfig memory t, SaleConfig memory s) {
        require(creator != address(0), "presale: zero creator");
        require(infra.treasury != address(0), "presale: zero treasury");
        require(infra.keeper != address(0), "presale: zero keeper");
        require(address(infra.stockSwapExecutor) != address(0), "presale: zero executor");
        require(s.hardCap >= s.softCap && s.softCap > 0, "presale: bad caps");
        require(s.end > s.start && s.start >= block.timestamp, "presale: bad window");
        require(s.salePct > 0 && s.lpPct > 0, "presale: zero alloc");
        require(uint256(s.salePct) + s.lpPct <= 100, "presale: alloc over 100");
        require(s.lpLockDuration >= infra.locker.MIN_DURATION(), "presale: lock too short");
        require(s.lpLockDuration <= 3650 days, "presale: lock too long");
        require(s.teamEnd >= s.teamCliff && s.teamCliff >= s.end, "presale: bad team vest");
        require(t.totalSupply > 0, "presale: zero supply");
        // validate here (not just in the token constructor at finalize) so a
        // presale that would fail to deploy its token can never collect ETH.
        // Bounds mirror ArchToken.MIN_TAX_BPS / MAX_TAX_BPS.
        require(t.taxBps >= 100 && t.taxBps <= 500, "presale: tax out of range");
        // Mirror ArchToken.MAX_CREATOR_FEE_BPS (100) / MAX_TOTAL_BPS (600).
        require(t.creatorFeeBps <= 100, "presale: creator fee too high");
        require(uint256(t.taxBps) + t.creatorFeeBps <= 600, "presale: total fee too high");
        require(address(t.stock) != address(0), "presale: zero stock");
        require(
            s.poolFee == 100 || s.poolFee == 500 || s.poolFee == 3000 || s.poolFee == 10000, "presale: bad pool fee"
        );

        CREATOR = creator;
        TREASURY = infra.treasury;
        LOCKER = infra.locker;
        NFPM = infra.nfpm;
        SWAP_ROUTER = infra.swapRouter;
        WETH = infra.weth;
        POOL_FEE = s.poolFee;
        STOCK_POOL_FEE = infra.stockPoolFee;
        STOCK_SWAP_EXECUTOR = infra.stockSwapExecutor;
        KEEPER = infra.keeper;

        tokenName = t.name;
        tokenSymbol = t.symbol;
        TOTAL_SUPPLY = t.totalSupply;
        TAX_BPS = t.taxBps;
        CREATOR_FEE_BPS = t.creatorFeeBps;
        STOCK = t.stock;

        SOFT_CAP = s.softCap;
        HARD_CAP = s.hardCap;
        START = s.start;
        END = s.end;
        PER_WALLET_CAP = s.perWalletCap;
        LP_LOCK_DURATION = s.lpLockDuration;
        TEAM_CLIFF = s.teamCliff;
        TEAM_END = s.teamEnd;

        uint256 saleTokens = (t.totalSupply * s.salePct) / 100;
        uint256 lpTokens = (t.totalSupply * s.lpPct) / 100;
        require(saleTokens > 0 && lpTokens > 0, "presale: alloc rounds to zero");
        SALE_TOKENS = saleTokens;
        LP_TOKENS = lpTokens;
        TEAM_TOKENS = t.totalSupply - saleTokens - lpTokens;
        // fixed price: a full hard-cap raise sells exactly SALE_TOKENS
        TOKENS_PER_ETH = (saleTokens * 1e18) / s.hardCap;
        require(TOKENS_PER_ETH > 0, "presale: price rounds to zero");

        // A successful sale may settle anywhere from soft cap to hard cap.
        // Validate both endpoints and both possible token address orderings now,
        // before contributions can be accepted. The seed ratio is monotonic
        // between the endpoints, so this proves every possible settlement price
        // is representable by both our price math and a real Uniswap V3 pool.
        _validateSeedRatio(lpTokens, _liquidityEth(s.softCap));
        _validateSeedRatio(lpTokens, _liquidityEth(s.hardCap));
    }

    /* ── contribute ──────────────────────────────────────────────── */

    function contribute() external payable nonReentrant {
        require(block.timestamp >= START && block.timestamp < END, "presale: not open");
        require(!finalized && !canceled, "presale: closed");
        require(msg.value > 0, "presale: zero value");
        require(totalRaised + msg.value <= HARD_CAP, "presale: over hard cap");

        uint256 newContribution = contributed[msg.sender] + msg.value;
        if (PER_WALLET_CAP > 0) {
            require(newContribution <= PER_WALLET_CAP, "presale: over wallet cap");
        }
        contributed[msg.sender] = newContribution;
        totalRaised += msg.value;
        // fold each contribution into the salt entropy: the final value depends
        // on who contributed, how much, and when, so it is unknown until the
        // sale closes and cannot be predicted at presale-creation time
        _entropy = keccak256(abi.encode(_entropy, msg.sender, msg.value, block.number, block.timestamp));
        emit Contributed(msg.sender, msg.value, newContribution);
    }

    /* ── finalize / cancel ───────────────────────────────────────── */

    /// @notice After the window closes with the soft cap met, deploy the
    ///         token, route the raise (minus fee) into locked liquidity, and
    ///         open claims. Callable by anyone; all outcomes are fixed by
    ///         config, so there is no privileged discretion.
    function finalize() external nonReentrant {
        require(!finalized && !canceled, "presale: already settled");
        require(block.timestamp >= END || totalRaised == HARD_CAP, "presale: not ended");
        require(totalRaised >= SOFT_CAP, "presale: soft cap missed");

        uint256 fee = (totalRaised * RAISE_FEE_BPS) / 10_000;
        uint256 lpEth = totalRaised - fee;

        // Deploy via CREATE2 with an entropy- and block-derived salt. Fund
        // safety does not rest on this: a pre-initialized pool is caught by the
        // price guard below, which cancels to full refunds. The salt raises the
        // cost of the liveness griefing by rotating the address every block and
        // mixing in the per-contribution entropy; where block entropy is real
        // the address is not knowable ahead of time, and on Arbitrum Orbit
        // (constant prevrandao) blockhash still rotates it per block. Either
        // way, a griefed launch downgrades to a refund, never a lock.
        bytes32 salt = keccak256(
            abi.encode(
                address(this), _entropy, blockhash(block.number - 1), block.number, block.timestamp, block.prevrandao
            )
        );
        // deployed via the delegatecall library so the token creation code is not
        // inlined here (keeps the presale + its deployer under the size limit);
        // the CREATE2 runs from this contract, so the token address and its
        // FACTORY are the same as a direct new ArchToken{salt}
        ArchToken t = ArchTokenDeployLib.deploy(
            tokenName,
            tokenSymbol,
            TOTAL_SUPPLY,
            TAX_BPS,
            STOCK,
            ArchToken.DexConfig({
                swapRouter: SWAP_ROUTER,
                weth: WETH,
                tokenPoolFee: POOL_FEE,
                stockPoolFee: STOCK_POOL_FEE,
                stockSwapExecutor: STOCK_SWAP_EXECUTOR
            }),
            TREASURY,
            KEEPER,
            CREATOR_FEE_BPS,
            CREATOR,
            salt
        );

        // Create + price-verify the launch pool BEFORE any irreversible step.
        // In V3 anyone can pre-initialize the (deterministic) pool for zero
        // liquidity, and createAndInitialize...() is a no-op on an existing
        // pool, so it cannot be trusted to set the price. If a griefer front-ran
        // it to a hostile price, seeding at the wrong ratio would strand the
        // raise (mint reverts or leaves the ETH as dead liquidity) with the soft
        // cap met and refunds closed, permanently locking contributor ETH.
        // Instead: detect the tampered price and cancel to refunds. The freshly
        // deployed token is orphaned but harmless (its supply sits in this
        // now-canceled contract and its wiring is never finalized).
        (address p, uint160 wantSqrt) = _preparePool(address(t), lpEth);
        (uint160 gotSqrt,,,,,,) = IUniswapV3PoolMinimal(p).slot0();
        if (gotSqrt != wantSqrt) {
            canceled = true;
            emit Canceled();
            return;
        }

        finalized = true;
        token = t;
        pair = p;
        t.addMarketPair(p);

        // fee to treasury, then everything else is locked liquidity
        (bool okFee,) = TREASURY.call{value: fee}("");
        require(okFee, "presale: fee send failed");

        // exclude all infrastructure and custody addresses from dividends so
        // unclaimed, team-held and locked tokens do not strand stock payouts
        t.setDividendExempt(address(this));
        t.setDividendExempt(address(t));
        t.setDividendExempt(DEAD);
        t.setDividendExempt(address(LOCKER));

        // seed and lock liquidity: every raised wei minus fee becomes a
        // full-range V3 position, locked for the creator
        uint256 lockId = _seedAndLockLiquidity(t, lpEth);

        // burn sale tokens that went unsold in an under-filled raise. Team
        // tokens remain in this contract and vest to the creator via
        // claimTeam(); contributor tokens remain for claim().
        uint256 sold = (totalRaised * TOKENS_PER_ETH) / 1e18;
        uint256 unsold = SALE_TOKENS - sold;
        if (unsold > 0) IERC20(address(t)).safeTransfer(DEAD, unsold);

        t.finalizeWiring();
        emit Finalized(address(t), p, totalRaised, lpEth, lockId);
    }

    /// @dev Compute the intended seed price and create + initialize the V3 pool
    ///      at it. Returns the pool and the intended sqrtPriceX96 so the caller
    ///      can compare it against the pool's real price (a no-op create on a
    ///      pre-existing griefed pool leaves the hostile price in place).
    function _preparePool(address tok, uint256 lpEth) private returns (address p, uint160 wantSqrt) {
        (address token0, address token1) = UniV3.sortTokens(tok, address(WETH));
        (uint256 amount0, uint256 amount1) = token0 == tok ? (LP_TOKENS, lpEth) : (lpEth, LP_TOKENS);
        wantSqrt = UniV3.sqrtPriceX96(amount0, amount1);
        p = NFPM.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, wantSqrt);
    }

    function _liquidityEth(uint256 raised) private pure returns (uint256) {
        return raised - (raised * RAISE_FEE_BPS) / 10_000;
    }

    function _validateSeedRatio(uint256 lpTokens, uint256 lpEth) private pure {
        // The CREATE2 token address is not known when this constructor runs, so
        // validate both address-sort outcomes. These calls revert on unsupported
        // ratios; doing that here keeps an invalid sale from ever collecting ETH.
        UniV3.sqrtPriceX96(lpTokens, lpEth);
        UniV3.sqrtPriceX96(lpEth, lpTokens);
    }

    /// @dev Wrap the ETH and mint a full-range position on the already
    ///      created + price-verified pool, then lock the NFT for the creator.
    function _seedAndLockLiquidity(ArchToken t, uint256 lpEth) private returns (uint256 lockId) {
        WETH.deposit{value: lpEth}();

        (address token0, address token1) = UniV3.sortTokens(address(t), address(WETH));
        (uint256 amount0, uint256 amount1) = token0 == address(t) ? (LP_TOKENS, lpEth) : (lpEth, LP_TOKENS);

        t.approve(address(NFPM), LP_TOKENS);
        IERC20(address(WETH)).forceApprove(address(NFPM), lpEth);
        (int24 tickLower, int24 tickUpper) = UniV3.fullRangeTicks(POOL_FEE);
        (uint256 tokenId,,,) = NFPM.mint(
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
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        NFPM.approve(address(LOCKER), tokenId);
        lockId = LOCKER.lock(NFPM, tokenId, uint64(block.timestamp) + LP_LOCK_DURATION, CREATOR);
    }

    /// @notice After the window closes below the soft cap, open refunds.
    function cancel() external nonReentrant {
        require(!finalized && !canceled, "presale: already settled");
        require(block.timestamp >= END, "presale: not ended");
        require(totalRaised < SOFT_CAP, "presale: soft cap met");
        canceled = true;
        emit Canceled();
    }

    /* ── claim / refund ──────────────────────────────────────────── */

    function claim() external nonReentrant {
        require(finalized, "presale: not finalized");
        require(!claimed[msg.sender], "presale: already claimed");
        uint256 amount = (contributed[msg.sender] * TOKENS_PER_ETH) / 1e18;
        require(amount > 0, "presale: nothing to claim");
        claimed[msg.sender] = true;
        IERC20(address(token)).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function refund() external nonReentrant {
        require(canceled, "presale: not canceled");
        uint256 amount = contributed[msg.sender];
        require(amount > 0, "presale: nothing to refund");
        contributed[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "presale: refund failed");
        emit Refunded(msg.sender, amount);
    }

    /* ── team vesting (cliff + linear, creator only) ─────────────── */

    /// @notice Team tokens vested so far. Linear from END to TEAM_END, with
    ///         nothing before TEAM_CLIFF. Enforced by this contract; the team
    ///         cannot pull tokens ahead of schedule.
    function teamVested() public view returns (uint256) {
        if (!finalized || block.timestamp < TEAM_CLIFF) return 0;
        if (block.timestamp >= TEAM_END) return TEAM_TOKENS;
        return (TEAM_TOKENS * (block.timestamp - END)) / (TEAM_END - END);
    }

    function claimTeam() external nonReentrant {
        require(msg.sender == CREATOR, "presale: not creator");
        uint256 amount = teamVested() - teamReleased;
        require(amount > 0, "presale: nothing vested");
        teamReleased += amount;
        IERC20(address(token)).safeTransfer(CREATOR, amount);
        emit TeamClaimed(amount);
    }

    /// @notice Tokens a contributor will receive at claim.
    function claimable(address who) external view returns (uint256) {
        if (claimed[who]) return 0;
        return (contributed[who] * TOKENS_PER_ETH) / 1e18;
    }
}
