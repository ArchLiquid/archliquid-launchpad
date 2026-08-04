// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {INonfungiblePositionManager, ISwapRouter} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {IUniswapV4PositionManager, PoolKey} from "../../src/interfaces/IUniswapV4.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fee-on-transfer token for locker/vesting shortfall tests.
contract MockFeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 1) {
            uint256 burn = value / 100; // 1% burned in transit
            super._update(from, address(0x000000000000000000000000000000000000dEaD), burn);
            super._update(from, to, value - burn);
        } else {
            super._update(from, to, value);
        }
    }
}

interface IERC3156FlashBorrowerMock {
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external returns (bytes32);
}

/// @dev ERC-3156 flash borrower for testing ArchCErc20. Configurable to repay
///      or not, and to return a wrong callback value. Must be pre-funded with
///      enough underlying to cover the fee.
contract MockFlashBorrower is IERC3156FlashBorrowerMock {
    bytes32 internal constant SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bool public repay = true;
    bytes32 public retVal = SUCCESS;
    uint256 public lastFee;

    function setRepay(bool r) external {
        repay = r;
    }

    function setRetVal(bytes32 v) external {
        retVal = v;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        lastFee = fee;
        if (repay) {
            // approve the lender (msg.sender) to pull principal + fee
            MockERC20(token).approve(msg.sender, amount + fee);
        }
        return retVal;
    }
}

/// @dev Minimal Chainlink AggregatorV3 mock with a settable answer.
contract MockAggregator {
    uint8 public decimals;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = 1;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

contract MockV2Pair is ERC20 {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    constructor(address factory_, address token0_, address token1_) ERC20("Mock V2 LP", "mV2-LP") {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function sync() external {
        _reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        _reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
        _blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }
}

/// @dev Minimal combined V2 factory + router. Pairs expose the canonical V2
///      identity surface; swap outputs are preset by the test.
contract MockDex is IUniswapV2Factory, IUniswapV2Router02 {
    address private immutable _weth;
    MockERC20 public immutable stock;

    mapping(address => mapping(address => address)) private _pairs;
    address[] public allPairs;
    uint256 public nextEthOut;
    uint256 public nextStockOut;

    constructor(MockERC20 stock_) {
        _weth = address(new MockERC20("Wrapped ETH", "WETH"));
        stock = stock_;
    }

    receive() external payable {}

    function setSwapOutputs(uint256 ethOut, uint256 stockOut) external {
        nextEthOut = ethOut;
        nextStockOut = stockOut;
    }

    function WETH() external view returns (address) {
        return _weth;
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB && tokenA != address(0) && tokenB != address(0), "mockdex: invalid pair");
        require(_pairs[tokenA][tokenB] == address(0), "mockdex: pair exists");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new MockV2Pair(address(this), token0, token1));
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
        allPairs.push(pair);
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[tokenA][tokenB];
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        address pair = _pairs[token][_weth];
        require(pair != address(0), "mockdex: no pair");
        require(IERC20(token).transferFrom(msg.sender, pair, amountTokenDesired), "mockdex: token transfer failed");
        uint256 liquidity = 1000e18;
        MockV2Pair(pair).mint(to, liquidity);
        return (amountTokenDesired, msg.value, liquidity);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(amountADesired >= amountAMin && amountBDesired >= amountBMin, "mockdex: liquidity slippage");
        address pair = _pairs[tokenA][tokenB];
        if (pair == address(0)) pair = this.createPair(tokenA, tokenB);
        require(IERC20(tokenA).transferFrom(msg.sender, pair, amountADesired), "mockdex: tokenA transfer failed");
        require(IERC20(tokenB).transferFrom(msg.sender, pair, amountBDesired), "mockdex: tokenB transfer failed");
        MockV2Pair(pair).sync();
        liquidity = 1000e18;
        MockV2Pair(pair).mint(to, liquidity);
        return (amountADesired, amountBDesired, liquidity);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        require(nextEthOut >= amountOutMin, "mockdex: eth slippage");
        // real routers move sold tokens into the pair, not the router
        address pair = _pairs[path[0]][path[1]];
        require(
            IERC20(path[0]).transferFrom(msg.sender, pair == address(0) ? address(this) : pair, amountIn),
            "mockdex: token transfer failed"
        );
        (bool ok,) = to.call{value: nextEthOut}("");
        require(ok, "mockdex: eth send failed");
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        require(path.length == 2, "mockdex: invalid path");
        address pair = _pairs[path[0]][path[1]];
        require(pair != address(0), "mockdex: no pair");
        require(IERC20(path[0]).transferFrom(msg.sender, pair, amountIn), "mockdex: token transfer failed");
        require(nextStockOut >= amountOutMin, "mockdex: stock slippage");
        stock.mint(to, nextStockOut);
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata, address to, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        require(nextStockOut >= amountOutMin, "mockdex: stock slippage");
        stock.mint(to, nextStockOut);
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = nextStockOut;
    }
}

/* ── Uniswap V3 mocks ─────────────────────────────────────────────── */

/// @dev Wrapped ETH: mint on deposit, burn + return ETH on withdraw.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth: eth send failed");
    }
}

/// @dev A placeholder V3 pool that records its init price and holds liquidity.
contract MockV3Pool {
    uint160 public sqrtPriceX96;

    constructor(uint160 price) {
        sqrtPriceX96 = price;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
}

/// @dev Minimal ERC-721 implementation used by the NFPM test double. Keeping
/// this local avoids pulling OpenZeppelin's Cancun-only Bytes utility into the
/// testnet mock deployment, which must compile for Robinhood's Paris-era EVM.
contract MockPositionNFT {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _approvals;

    function ownerOf(uint256 tokenId) public view virtual returns (address owner) {
        owner = _owners[tokenId];
        require(owner != address(0), "nft: nonexistent token");
    }

    function approve(address to, uint256 tokenId) public virtual {
        require(msg.sender == ownerOf(tokenId), "nft: not owner");
        _approvals[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual {
        require(ownerOf(tokenId) == from, "nft: wrong owner");
        require(msg.sender == from || msg.sender == _approvals[tokenId], "nft: not approved");
        require(to != address(0), "nft: zero recipient");
        _owners[tokenId] = to;
        delete _approvals[tokenId];
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public virtual {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "nft: receiver rejected"
            );
        }
    }

    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0) && _owners[tokenId] == address(0), "nft: invalid mint");
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }
}

/// @dev Minimal Uniswap V3 NonfungiblePositionManager: creates placeholder
///      pools, pulls the seeded tokens to the pool (modeling V3 paying the pool
///      directly from the payer), and mints an ERC-721 position NFT.
contract MockNFPM is MockPositionNFT {
    uint256 public nextId = 1;
    mapping(bytes32 => address) public poolOf;
    bool public griefNext; // simulate a pool pre-initialized at a hostile price

    /// @dev When set, the next pool creation ignores the requested price and
    ///      initializes at a hostile price (1), modeling a griefer that
    ///      pre-initialized the pool. Lets tests exercise the price guard
    ///      without predicting the (now CREATE2-randomized) token address.
    function setGriefNext(bool v) external {
        griefNext = v;
    }

    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encode(a, b, fee));
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool)
    {
        bytes32 k = _key(token0, token1, fee);
        pool = poolOf[k];
        // initialize only if the pool does not yet exist (V3 semantics)
        if (pool == address(0)) {
            uint160 price = griefNext ? 1 : sqrtPriceX96;
            griefNext = false;
            pool = address(new MockV3Pool(price));
            poolOf[k] = pool;
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address pool = poolOf[_key(p.token0, p.token1, p.fee)];
        require(pool != address(0), "nfpm: no pool");
        // pay the pool directly from the caller (V3 mint-callback semantics)
        require(IERC20(p.token0).transferFrom(msg.sender, pool, p.amount0Desired), "nfpm: token0 transfer failed");
        require(IERC20(p.token1).transferFrom(msg.sender, pool, p.amount1Desired), "nfpm: token1 transfer failed");
        tokenId = nextId++;
        _mint(p.recipient, tokenId);
        return (tokenId, 1e18, p.amount0Desired, p.amount1Desired);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata) external payable returns (uint256, uint256) {
        return (0, 0);
    }
}

/* ── Uniswap V4 mocks ─────────────────────────────────────────────── */

contract MockV4PoolManager {}

contract MockV4PositionManager is MockPositionNFT, IUniswapV4PositionManager {
    address public immutable poolManager;
    uint256 public nextTokenId = 1;
    mapping(uint256 => address) public subscriber;

    mapping(uint256 => PoolKey) private _poolKeys;
    mapping(uint256 => uint128) private _liquidity;
    mapping(uint256 => uint256) public fees0;
    mapping(uint256 => uint256) public fees1;
    bool public mutatePrincipalOnCollect;
    bytes32 public lastHookDataHash;

    constructor(address poolManager_) {
        poolManager = poolManager_;
    }

    receive() external payable {}

    function mintPosition(address to, PoolKey calldata key, uint128 liquidity, address subscriber_)
        external
        returns (uint256 tokenId)
    {
        tokenId = nextTokenId++;
        _poolKeys[tokenId] = key;
        _liquidity[tokenId] = liquidity;
        subscriber[tokenId] = subscriber_;
        _mint(to, tokenId);
    }

    function setFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        ownerOf(tokenId);
        fees0[tokenId] = amount0;
        fees1[tokenId] = amount1;
    }

    function setMutatePrincipalOnCollect(bool value) external {
        mutatePrincipalOnCollect = value;
    }

    function ownerOf(uint256 tokenId)
        public
        view
        override(MockPositionNFT, IUniswapV4PositionManager)
        returns (address owner)
    {
        return super.ownerOf(tokenId);
    }

    function approve(address to, uint256 tokenId) public override(MockPositionNFT, IUniswapV4PositionManager) {
        super.approve(to, tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        super.transferFrom(from, to, tokenId);
        delete subscriber[tokenId];
    }

    function safeTransferFrom(address from, address to, uint256 tokenId)
        public
        override(MockPositionNFT, IUniswapV4PositionManager)
    {
        super.safeTransferFrom(from, to, tokenId);
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        ownerOf(tokenId);
        return _liquidity[tokenId];
    }

    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory poolKey, uint256 positionInfo)
    {
        ownerOf(tokenId);
        return (_poolKeys[tokenId], 0);
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        require(deadline >= block.timestamp, "v4: expired");
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(
            actions.length == 2 && uint8(actions[0]) == 0x01 && uint8(actions[1]) == 0x11 && params.length == 2,
            "v4: wrong actions"
        );

        (uint256 tokenId, uint256 liquidityToRemove, uint128 amount0Min, uint128 amount1Min, bytes memory hookData) =
            abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
        require(ownerOf(tokenId) == msg.sender, "v4: not owner");
        require(liquidityToRemove == 0 && amount0Min == 0 && amount1Min == 0, "v4: principal requested");

        (address currency0, address currency1, address recipient) = abi.decode(params[1], (address, address, address));
        PoolKey memory key = _poolKeys[tokenId];
        require(currency0 == key.currency0 && currency1 == key.currency1, "v4: wrong currencies");
        lastHookDataHash = keccak256(hookData);

        if (mutatePrincipalOnCollect) _liquidity[tokenId] -= 1;

        uint256 amount0 = fees0[tokenId];
        uint256 amount1 = fees1[tokenId];
        delete fees0[tokenId];
        delete fees1[tokenId];
        _pay(currency0, recipient, amount0);
        _pay(currency1, recipient, amount1);
    }

    function _pay(address currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            require(ok, "v4: native transfer failed");
        } else {
            require(IERC20(currency).transfer(recipient, amount), "v4: token transfer failed");
        }
    }
}

/// @dev Minimal Uniswap V3 SwapRouter: pulls the input from the caller and
///      mints a preset output to the recipient. Outputs are set by the test.
///      When an NFPM is registered, the input is routed to the corresponding
///      pool (as real V3 pays the pool directly from the payer) instead of being
///      custodied here; this keeps a taxed token's dividend accounting exact,
///      since the pool is a dividend-exempt market pair.
contract MockV3Router {
    mapping(address => uint256) public nextOut; // tokenOut => amount
    MockNFPM public nfpm; // optional; when set, route input to the pool

    function setNextOut(address tokenOut, uint256 amount) external {
        nextOut[tokenOut] = amount;
    }

    function setNfpm(MockNFPM n) external {
        nfpm = n;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        address dest = address(this);
        if (address(nfpm) != address(0)) {
            (address a, address b) = p.tokenIn < p.tokenOut ? (p.tokenIn, p.tokenOut) : (p.tokenOut, p.tokenIn);
            address pool = nfpm.poolOf(keccak256(abi.encode(a, b, p.fee)));
            if (pool != address(0)) dest = pool;
        }
        require(IERC20(p.tokenIn).transferFrom(msg.sender, dest, p.amountIn), "router: input transfer failed");
        amountOut = nextOut[p.tokenOut];
        require(amountOut >= p.amountOutMinimum, "router: slippage");
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
