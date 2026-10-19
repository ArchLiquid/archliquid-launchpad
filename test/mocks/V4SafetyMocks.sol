// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV4StateView, PoolKey} from "../../src/interfaces/IUniswapV4.sol";

/// @dev Deterministic custody/approval fixtures, not an implementation of V4
///      pricing math. Real V4 integration remains covered by the fork suites.
contract V4SafetyWETH is ERC20 {
    constructor() ERC20("Safety Wrapped ETH", "sWETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "safety weth: refund");
    }
}

contract V4SafetyPermit2 {
    using SafeERC20 for IERC20;

    struct Approval {
        uint160 amount;
        uint48 expiration;
    }

    mapping(address => mapping(address => mapping(address => Approval))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender] = Approval(amount, expiration);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Approval storage approval = allowance[from][token][msg.sender];
        require(approval.expiration >= block.timestamp && approval.amount >= amount, "safety permit2: approval");
        approval.amount -= amount;
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}

contract V4SafetyPoolManager {
    mapping(bytes32 => uint160) public sqrtPrice;

    function initialize(PoolKey calldata key, uint160 price) external returns (int24) {
        bytes32 id = keccak256(abi.encode(key));
        require(sqrtPrice[id] == 0, "safety manager: initialized");
        sqrtPrice[id] = price;
        return 0;
    }
}

contract V4SafetyStateView is IUniswapV4StateView {
    address public immutable poolManager;

    constructor(address manager) {
        poolManager = manager;
    }

    function getSlot0(bytes32 id) external view returns (uint160, int24, uint24, uint24) {
        return (V4SafetyPoolManager(poolManager).sqrtPrice(id), 0, 0, 3000);
    }
}

contract V4SafetyPositionManager is ERC721 {
    address public immutable poolManager;
    address public immutable permit2;
    uint256 public nextTokenId = 1;
    mapping(uint256 => address) public subscriber;
    mapping(uint256 => PoolKey) private _poolKeys;
    mapping(uint256 => uint128) private _liquidity;

    uint16 public consumptionBps = 7500;
    bool public wrongPositionPool;
    uint8 public wrongPositionPoolKind;
    bool public wrongPositionOwner;
    bool public wrongPositionLiquidity;

    constructor(address manager, address permit) ERC721("Safety V4 Positions", "sV4") {
        poolManager = manager;
        permit2 = permit;
    }

    function setConsumptionBps(uint16 bps) external {
        require(bps > 0 && bps <= 10_000, "safety position: bps");
        consumptionBps = bps;
    }

    function setWrongPositionPool(bool value) external {
        wrongPositionPool = value;
    }

    function setWrongPositionPoolKind(uint8 kind) external {
        wrongPositionPoolKind = kind;
    }

    function setSubscriber(uint256 tokenId, address value) external {
        subscriber[tokenId] = value;
    }

    function setWrongPositionOwner(bool value) external {
        wrongPositionOwner = value;
    }

    function setWrongPositionLiquidity(bool value) external {
        wrongPositionLiquidity = value;
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        ownerOf(tokenId);
        return _liquidity[tokenId];
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256) {
        ownerOf(tokenId);
        return (_poolKeys[tokenId], 0);
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        require(block.timestamp <= deadline, "safety position: expired");
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(keccak256(actions) == keccak256(abi.encodePacked(uint8(0x02), uint8(0x0d))), "safety position: actions");
        require(params.length == 2, "safety position: params");
        (
            PoolKey memory key,
            int24 lower,
            int24 upper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address recipient,
            bytes memory hookData
        ) = abi.decode(params[0], (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        require(
            lower == -887220 && upper == 887220 && key.hooks == address(0) && hookData.length == 0,
            "safety position: policy"
        );
        (address currency0, address currency1) = abi.decode(params[1], (address, address));
        require(currency0 == key.currency0 && currency1 == key.currency1, "safety position: settlement");
        V4SafetyPermit2(permit2)
            .transferFrom(msg.sender, poolManager, uint160(uint256(amount0Max) * consumptionBps / 10_000), currency0);
        V4SafetyPermit2(permit2)
            .transferFrom(msg.sender, poolManager, uint160(uint256(amount1Max) * consumptionBps / 10_000), currency1);
        uint256 tokenId = nextTokenId++;
        _poolKeys[tokenId] = key;
        if (wrongPositionPool || wrongPositionPoolKind == 1) _poolKeys[tokenId].fee = 500;
        if (wrongPositionPoolKind == 2) _poolKeys[tokenId].currency0 = address(0xbad);
        if (wrongPositionPoolKind == 3) {
            _poolKeys[tokenId].hooks = address(0xbad);
            _poolKeys[tokenId].tickSpacing = 10;
        }
        _liquidity[tokenId] = uint128(liquidity) + (wrongPositionLiquidity ? 1 : 0);
        _mint(wrongPositionOwner ? address(0xbad) : recipient, tokenId);
    }
}
