// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchTokenDeployLib} from "./lib/ArchTokenDeployLib.sol";
import {IArchStockSwapExecutor} from "@archliquid/core/interfaces/IArchStockSwapExecutor.sol";
import {IArchLaunchLiquidityAdapter} from "./interfaces/IArchLaunchLiquidityAdapter.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

/// @title ArchAdapterPresale
/// @notice Fixed-price presale for a versioned AMM adapter. The successful
///         raise seeds adapter-custodied liquidity; a failed pool preparation
///         leaves the full raise refundable.
contract ArchAdapterPresale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 public constant RAISE_FEE_BPS = 300;
    uint64 public constant MIN_LP_LOCK = 30 days;

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

    struct SaleConfig {
        uint128 softCap;
        uint128 hardCap;
        uint64 start;
        uint64 end;
        uint128 perWalletCap;
        uint16 salePct;
        uint16 lpPct;
        uint24 poolFee;
        uint64 lpLockDuration;
        uint64 teamCliff;
        uint64 teamEnd;
    }

    address public immutable CREATOR;
    address payable public immutable TREASURY;
    IArchLaunchLiquidityAdapter public immutable LIQUIDITY_ADAPTER;
    ISwapRouter public immutable SWAP_ROUTER;
    IWETH9 public immutable WETH;
    uint24 public immutable POOL_FEE;
    uint24 public immutable STOCK_POOL_FEE;
    IArchStockSwapExecutor public immutable STOCK_SWAP_EXECUTOR;
    address public immutable KEEPER;

    string public tokenName;
    string public tokenSymbol;
    uint256 public immutable TOTAL_SUPPLY;
    uint16 public immutable TAX_BPS;
    uint16 public immutable CREATOR_FEE_BPS;
    IERC20 public immutable STOCK;

    uint128 public immutable SOFT_CAP;
    uint128 public immutable HARD_CAP;
    uint64 public immutable START;
    uint64 public immutable END;
    uint128 public immutable PER_WALLET_CAP;
    uint256 public immutable TOKENS_PER_ETH;
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
    bytes32 private _entropy;

    bool public finalized;
    bool public canceled;
    ArchToken public token;
    address public pair;
    bytes32 public poolId;

    event Contributed(address indexed who, uint256 amount, uint256 total);
    event Finalized(
        address indexed token,
        address indexed market,
        bytes32 indexed poolId,
        uint256 raised,
        uint256 wethSeeded,
        uint256 positionIdOrAmount,
        uint256 lockId
    );
    event Canceled();
    event Claimed(address indexed who, uint256 tokenAmount);
    event Refunded(address indexed who, uint256 amount);
    event TeamClaimed(uint256 tokenAmount);

    /// @dev Accept native ETH only from the immutable WETH contract while
    ///      unwrapping V4 rounding dust after liquidity seeding.
    receive() external payable {
        require(msg.sender == address(WETH), "adapter presale: only weth");
    }

    constructor(address creator, Infra memory infra, TokenConfig memory t, SaleConfig memory s) {
        require(creator != address(0), "adapter presale: zero creator");
        require(infra.treasury != address(0), "adapter presale: zero treasury");
        require(address(infra.liquidityAdapter).code.length > 0, "adapter presale: invalid adapter");
        require(address(infra.swapRouter).code.length > 0, "adapter presale: invalid router");
        require(address(infra.weth).code.length > 0, "adapter presale: invalid weth");
        require(infra.liquidityAdapter.weth() == address(infra.weth), "adapter presale: weth mismatch");
        require(infra.keeper != address(0), "adapter presale: zero keeper");
        require(address(infra.stockSwapExecutor) != address(0), "adapter presale: zero executor");
        require(s.hardCap >= s.softCap && s.softCap > 0, "adapter presale: bad caps");
        require(s.end > s.start && s.start >= block.timestamp, "adapter presale: bad window");
        require(s.salePct > 0 && s.lpPct > 0, "adapter presale: zero alloc");
        require(uint256(s.salePct) + s.lpPct <= 100, "adapter presale: alloc over 100");
        require(s.poolFee == infra.tokenPoolFee, "adapter presale: wrong pool fee");
        require(s.lpLockDuration >= MIN_LP_LOCK && s.lpLockDuration <= 3650 days, "adapter presale: bad lock");
        require(s.teamEnd >= s.teamCliff && s.teamCliff >= s.end, "adapter presale: bad team vest");
        require(t.totalSupply > 0, "adapter presale: zero supply");
        require(t.taxBps >= 100 && t.taxBps <= 500, "adapter presale: tax out of range");
        require(
            t.creatorFeeBps <= 100 && uint256(t.taxBps) + t.creatorFeeBps <= 600, "adapter presale: fee out of range"
        );
        require(address(t.stock) != address(0), "adapter presale: zero stock");

        CREATOR = creator;
        TREASURY = infra.treasury;
        LIQUIDITY_ADAPTER = infra.liquidityAdapter;
        SWAP_ROUTER = infra.swapRouter;
        WETH = infra.weth;
        POOL_FEE = infra.tokenPoolFee;
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
        require(saleTokens > 0 && lpTokens > 0, "adapter presale: allocation rounds to zero");
        SALE_TOKENS = saleTokens;
        LP_TOKENS = lpTokens;
        TEAM_TOKENS = t.totalSupply - saleTokens - lpTokens;
        TOKENS_PER_ETH = (saleTokens * 1e18) / s.hardCap;
        require(TOKENS_PER_ETH > 0, "adapter presale: price rounds to zero");

        infra.liquidityAdapter.validateSeedAmounts(lpTokens, _liquidityEth(s.softCap));
        infra.liquidityAdapter.validateSeedAmounts(lpTokens, _liquidityEth(s.hardCap));
    }

    function contribute() external payable nonReentrant {
        require(block.timestamp >= START && block.timestamp < END, "adapter presale: not open");
        require(!finalized && !canceled, "adapter presale: closed");
        require(msg.value > 0, "adapter presale: zero value");
        require(totalRaised + msg.value <= HARD_CAP, "adapter presale: over hard cap");
        uint256 newContribution = contributed[msg.sender] + msg.value;
        if (PER_WALLET_CAP > 0) require(newContribution <= PER_WALLET_CAP, "adapter presale: over wallet cap");
        contributed[msg.sender] = newContribution;
        totalRaised += msg.value;
        _entropy = keccak256(abi.encode(_entropy, msg.sender, msg.value, block.number, block.timestamp));
        emit Contributed(msg.sender, msg.value, newContribution);
    }

    function finalize() external nonReentrant {
        require(!finalized && !canceled, "adapter presale: already settled");
        require(block.timestamp >= END || totalRaised == HARD_CAP, "adapter presale: not ended");
        require(totalRaised >= SOFT_CAP, "adapter presale: soft cap missed");

        uint256 fee = (totalRaised * RAISE_FEE_BPS) / 10_000;
        uint256 lpEth = totalRaised - fee;
        bytes32 salt = keccak256(
            abi.encode(
                address(this), _entropy, blockhash(block.number - 1), block.number, block.timestamp, block.prevrandao
            )
        );
        ArchToken created = ArchTokenDeployLib.deploy(
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

        created.setDividendExempt(address(this));
        created.setDividendExempt(address(created));
        created.setDividendExempt(DEAD);
        created.setDividendExempt(address(LIQUIDITY_ADAPTER));

        WETH.deposit{value: lpEth}();
        IERC20(address(created)).forceApprove(address(LIQUIDITY_ADAPTER), LP_TOKENS);
        IERC20(address(WETH)).forceApprove(address(LIQUIDITY_ADAPTER), lpEth);

        IArchLaunchLiquidityAdapter.SeedResult memory seeded;
        try LIQUIDITY_ADAPTER.seed(
            IArchLaunchLiquidityAdapter.SeedParams({
                token: address(created),
                tokenAmount: LP_TOKENS,
                wethAmount: lpEth,
                lockOwner: CREATOR,
                unlockTime: uint64(block.timestamp) + LP_LOCK_DURATION,
                permanent: false
            })
        ) returns (
            IArchLaunchLiquidityAdapter.SeedResult memory result
        ) {
            seeded = result;
        } catch {
            IERC20(address(created)).forceApprove(address(LIQUIDITY_ADAPTER), 0);
            IERC20(address(WETH)).forceApprove(address(LIQUIDITY_ADAPTER), 0);
            WETH.withdraw(lpEth);
            canceled = true;
            emit Canceled();
            return;
        }

        IERC20(address(created)).forceApprove(address(LIQUIDITY_ADAPTER), 0);
        IERC20(address(WETH)).forceApprove(address(LIQUIDITY_ADAPTER), 0);
        require(seeded.tokenUsed > 0 && seeded.wethUsed > 0, "adapter presale: empty seed");
        require(seeded.tokenUsed <= LP_TOKENS && seeded.wethUsed <= lpEth, "adapter presale: seed overflow");

        finalized = true;
        token = created;
        pair = seeded.market;
        poolId = seeded.poolId;
        created.addMarketPair(seeded.market);
        created.setDividendExempt(seeded.positionManager);

        uint256 wethDust = lpEth - seeded.wethUsed;
        if (wethDust > 0) WETH.withdraw(wethDust);
        (bool paid,) = TREASURY.call{value: fee + wethDust}("");
        require(paid, "adapter presale: fee send failed");

        uint256 lpTokenDust = LP_TOKENS - seeded.tokenUsed;
        if (lpTokenDust > 0) IERC20(address(created)).safeTransfer(DEAD, lpTokenDust);
        uint256 sold = (totalRaised * TOKENS_PER_ETH) / 1e18;
        uint256 unsold = SALE_TOKENS - sold;
        if (unsold > 0) IERC20(address(created)).safeTransfer(DEAD, unsold);

        created.finalizeWiring();
        emit Finalized(
            address(created),
            seeded.market,
            seeded.poolId,
            totalRaised,
            seeded.wethUsed,
            seeded.positionIdOrAmount,
            seeded.lockId
        );
    }

    function cancel() external nonReentrant {
        require(!finalized && !canceled, "adapter presale: already settled");
        require(block.timestamp >= END, "adapter presale: not ended");
        require(totalRaised < SOFT_CAP, "adapter presale: soft cap met");
        canceled = true;
        emit Canceled();
    }

    function claim() external nonReentrant {
        require(finalized, "adapter presale: not finalized");
        require(!claimed[msg.sender], "adapter presale: already claimed");
        uint256 amount = (contributed[msg.sender] * TOKENS_PER_ETH) / 1e18;
        require(amount > 0, "adapter presale: nothing to claim");
        claimed[msg.sender] = true;
        IERC20(address(token)).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function refund() external nonReentrant {
        require(canceled, "adapter presale: not canceled");
        uint256 amount = contributed[msg.sender];
        require(amount > 0, "adapter presale: nothing to refund");
        contributed[msg.sender] = 0;
        (bool refunded,) = payable(msg.sender).call{value: amount}("");
        require(refunded, "adapter presale: refund failed");
        emit Refunded(msg.sender, amount);
    }

    function teamVested() public view returns (uint256) {
        if (!finalized || block.timestamp < TEAM_CLIFF) return 0;
        if (block.timestamp >= TEAM_END) return TEAM_TOKENS;
        return (TEAM_TOKENS * (block.timestamp - END)) / (TEAM_END - END);
    }

    function claimTeam() external nonReentrant {
        require(msg.sender == CREATOR, "adapter presale: not creator");
        uint256 amount = teamVested() - teamReleased;
        require(amount > 0, "adapter presale: nothing vested");
        teamReleased += amount;
        IERC20(address(token)).safeTransfer(CREATOR, amount);
        emit TeamClaimed(amount);
    }

    function claimable(address who) external view returns (uint256) {
        if (claimed[who]) return 0;
        return (contributed[who] * TOKENS_PER_ETH) / 1e18;
    }

    function _liquidityEth(uint256 raised) private pure returns (uint256) {
        return raised - (raised * RAISE_FEE_BPS) / 10_000;
    }
}
