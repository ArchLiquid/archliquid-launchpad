// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IArchLaunchLiquidityAdapter} from "../../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {INonfungiblePositionManager} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {UniV3} from "@archliquid/core/lib/UniV3.sol";
import {MockPositionNFT, MockV3Pool} from "./Mocks.sol";

/// @dev Offline seed/custody fixture. It exercises real launch arithmetic and
///      exact ERC20 movements without claiming canonical AMM math parity.
contract CurveSafetyAdapter is MockPositionNFT, IArchLaunchLiquidityAdapter {
    using SafeERC20 for IERC20;

    address public immutable weth;
    address public immutable market;
    uint256 public tokenDust;
    uint256 public wethDust;
    uint256 public tokenSeeded;
    uint256 public wethSeeded;
    bool public failSeed;
    bool public lieAboutConsumption;

    constructor(address weth_) {
        weth = weth_;
        market = address(new MockV3Pool(1));
    }

    function liquidityProvisioner() external view returns (address) {
        return address(this);
    }

    function setFailure(bool fail) external {
        failSeed = fail;
    }

    function setLyingConsumption(bool lie) external {
        lieAboutConsumption = lie;
    }

    function setDust(uint256 tokenDust_, uint256 wethDust_) external {
        tokenDust = tokenDust_;
        wethDust = wethDust_;
    }

    function validateSeedAmounts(uint256 tokens, uint256 wrappedEth) public pure {
        require(tokens > 0 && wrappedEth > 0, "fixture adapter: zero seed");
        require(tokens <= type(uint128).max && wrappedEth <= type(uint128).max, "fixture adapter: seed too large");
        UniV3.sqrtPriceX96(tokens, wrappedEth);
        UniV3.sqrtPriceX96(wrappedEth, tokens);
    }

    function seed(SeedParams calldata p) external returns (SeedResult memory) {
        require(!failSeed, "fixture adapter: failed seed");
        validateSeedAmounts(p.tokenAmount, p.wethAmount);
        require(p.permanent && p.lockOwner == address(0), "fixture adapter: custody changed");
        tokenSeeded = p.tokenAmount - tokenDust;
        wethSeeded = p.wethAmount - wethDust;
        IERC20(p.token).safeTransferFrom(msg.sender, market, tokenSeeded);
        IERC20(weth).safeTransferFrom(msg.sender, market, wethSeeded);
        _mint(0x000000000000000000000000000000000000dEaD, 1);
        return SeedResult(
            market,
            keccak256("curve-safety-fixture"),
            address(this),
            1,
            type(uint256).max,
            tokenSeeded + (lieAboutConsumption ? 1 : 0),
            wethSeeded
        );
    }
}

contract CurveSafetyNFPM is MockPositionNFT {
    using SafeERC20 for IERC20;

    address public immutable weth;
    mapping(bytes32 => address) public pools;
    uint256 public tokenDust;
    uint256 public wethDust;
    bool public lieAboutConsumption;
    bool public failMint;
    uint8 public invalidResult; // 1 zero id, 2 zero liquidity, 3 overflow, 4 wrong custody

    constructor(address weth_) {
        weth = weth_;
    }

    function setDust(uint256 tokenDust_, uint256 wethDust_) external {
        tokenDust = tokenDust_;
        wethDust = wethDust_;
    }

    function setFailure(bool fail) external {
        failMint = fail;
    }

    function setLyingConsumption(bool lie) external {
        lieAboutConsumption = lie;
    }

    function setInvalidResult(uint8 result) external {
        invalidResult = result;
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 price)
        external
        payable
        returns (address pool)
    {
        bytes32 key = keccak256(abi.encode(token0, token1, fee));
        pool = pools[key];
        if (pool == address(0)) {
            pool = address(new MockV3Pool(price));
            pools[key] = pool;
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(!failMint, "fixture nfpm: failed mint");
        address pool = pools[keccak256(abi.encode(p.token0, p.token1, p.fee))];
        require(pool != address(0), "fixture nfpm: no pool");
        amount0 = p.amount0Desired - (p.token0 == weth ? wethDust : tokenDust);
        amount1 = p.amount1Desired - (p.token1 == weth ? wethDust : tokenDust);
        IERC20(p.token0).safeTransferFrom(msg.sender, pool, amount0);
        IERC20(p.token1).safeTransferFrom(msg.sender, pool, amount1);
        _mint(invalidResult == 4 ? address(0xbad) : p.recipient, 1);
        uint256 reported0 = invalidResult == 3 ? p.amount0Desired + 1 : amount0 + (lieAboutConsumption ? 1 : 0);
        return (invalidResult == 1 ? 0 : 1, invalidResult == 2 ? 0 : 1, reported0, amount1);
    }
}
