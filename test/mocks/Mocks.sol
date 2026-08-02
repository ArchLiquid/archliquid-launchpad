// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "@archliquid/core/interfaces/IUniswapV2.sol";
import {INonfungiblePositionManager, ISwapRouter} from "@archliquid/core/interfaces/IUniswapV3.sol";

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

/// @dev Minimal combined V2 factory + router. Pairs are plain ERC20 LP
///      tokens; swap outputs are preset by the test.
contract MockDex is IUniswapV2Factory, IUniswapV2Router02 {
    address private immutable _weth;
    MockERC20 public immutable stock;

    mapping(address => mapping(address => address)) private _pairs;
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

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockERC20("LP", "LP"));
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[tokenA][tokenB];
    }

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        address pair = _pairs[token][_weth];
        require(pair != address(0), "mockdex: no pair");
        IERC20(token).transferFrom(msg.sender, pair, amountTokenDesired);
        uint256 liquidity = 1000e18;
        MockERC20(pair).mint(to, liquidity);
        return (amountTokenDesired, msg.value, liquidity);
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
        IERC20(path[0]).transferFrom(msg.sender, pair == address(0) ? address(this) : pair, amountIn);
        (bool ok,) = to.call{value: nextEthOut}("");
        require(ok, "mockdex: eth send failed");
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
    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _approvals;

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _owners[tokenId];
        require(owner != address(0), "nft: nonexistent token");
    }

    function approve(address to, uint256 tokenId) external {
        require(msg.sender == ownerOf(tokenId), "nft: not owner");
        _approvals[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(ownerOf(tokenId) == from, "nft: wrong owner");
        require(msg.sender == from || msg.sender == _approvals[tokenId], "nft: not approved");
        require(to != address(0), "nft: zero recipient");
        _owners[tokenId] = to;
        delete _approvals[tokenId];
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
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
        IERC20(p.token0).transferFrom(msg.sender, pool, p.amount0Desired);
        IERC20(p.token1).transferFrom(msg.sender, pool, p.amount1Desired);
        tokenId = nextId++;
        _mint(p.recipient, tokenId);
        return (tokenId, 1e18, p.amount0Desired, p.amount1Desired);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata) external payable returns (uint256, uint256) {
        return (0, 0);
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
        IERC20(p.tokenIn).transferFrom(msg.sender, dest, p.amountIn);
        amountOut = nextOut[p.tokenOut];
        require(amountOut >= p.amountOutMinimum, "router: slippage");
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
