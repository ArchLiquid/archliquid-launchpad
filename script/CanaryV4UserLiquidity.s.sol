// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {ArchAdapterTokenFactory} from "../src/ArchAdapterTokenFactory.sol";
import {ArchV4UserLiquidityProvisioner} from "../src/ArchV4UserLiquidityProvisioner.sol";
import {IArchLaunchLiquidityAdapter} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {IUniswapV4PositionManager, IUniswapV4StateView} from "../src/interfaces/IUniswapV4.sol";

/// @notice One-transaction bounded-value canary. Constructor failure reverts
///         token creation and both liquidity operations atomically.
contract V4UserLiquidityCanary {
    using SafeERC20 for IERC20;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    ArchAdapterTokenFactory private constant FACTORY =
        ArchAdapterTokenFactory(payable(0x897cd8ac993184d6dd3B549A5FbEc04f697C107c));
    ArchV4UserLiquidityProvisioner private constant PROVISIONER =
        ArchV4UserLiquidityProvisioner(payable(0xba8cB9EE1Ea1126535C22d13805ec5cC22613775));
    ArchV4PositionLocker private constant LOCKER = ArchV4PositionLocker(0x8A1bC51e25b8799a5da57ff55f0262A405Ed2b98);
    IUniswapV4PositionManager private constant POSITION_MANAGER =
        IUniswapV4PositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IUniswapV4StateView private constant STATE_VIEW = IUniswapV4StateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    IERC20 private constant STOCK = IERC20(0x1c80aC86447c8EEa5D0D70DCa78c632b7A249bEE);
    IERC20 private constant WETH = IERC20(0x61293a735E35d76E8980Bf17715b37A0C4196512);

    uint256 private constant TOKEN_AMOUNT = 100_000e18;
    uint256 private constant ETH_AMOUNT = 0.001 ether;

    ArchToken public immutable TOKEN;
    bytes32 public immutable POOL_ID;
    uint256 public immutable TIMED_POSITION;
    uint256 public immutable LOCK_ID;
    uint256 public immutable PERMANENT_POSITION;

    receive() external payable {
        require(msg.sender == address(PROVISIONER), "v4 canary: refund sender");
    }

    constructor(address provider) payable {
        require(provider != address(0) && msg.sender == provider, "v4 canary: provider");
        require(msg.value == FACTORY.FEE() + 2 * ETH_AMOUNT, "v4 canary: value");
        require(FACTORY.tokenCount() == 0, "v4 canary: release not fresh");

        ArchToken token = ArchToken(
            payable(FACTORY.createToken{value: FACTORY.FEE()}(
                    ArchAdapterTokenFactory.TokenParams({
                        name: "Arch V4 Liquidity Canary",
                        symbol: "AV4LC",
                        totalSupply: 1_000_000e18,
                        taxBps: 300,
                        stock: STOCK,
                        creatorFeeBps: 0
                    }),
                    ArchAdapterTokenFactory.LiquidityParams({
                        enabled: false, lpPct: 0, poolFee: 0, burnLp: false, lockDuration: 0
                    })
                ))
        );
        token.approve(address(PROVISIONER), 2 * TOKEN_AMOUNT);
        IArchLaunchLiquidityAdapter.SeedResult memory first = PROVISIONER.addLiquidity{value: ETH_AMOUNT}(
            token, TOKEN_AMOUNT, address(0), 1, type(uint160).max, 30 days, false
        );
        (uint160 sqrtPriceX96,,,) = STATE_VIEW.getSlot0(first.poolId);
        IArchLaunchLiquidityAdapter.SeedResult memory second = PROVISIONER.addLiquidity{value: ETH_AMOUNT}(
            token, TOKEN_AMOUNT, first.market, sqrtPriceX96, sqrtPriceX96, 0, true
        );

        require(token.marketPairCount() == 1 && token.isMarketPair(first.market), "v4 canary: market");
        require(first.market == address(PROVISIONER.ADAPTER().POOL_MANAGER()), "v4 canary: manager");
        require(first.poolId == second.poolId, "v4 canary: pool mismatch");
        require(POSITION_MANAGER.ownerOf(first.positionIdOrAmount) == address(LOCKER), "v4 canary: lock custody");
        require(POSITION_MANAGER.ownerOf(second.positionIdOrAmount) == DEAD, "v4 canary: burn custody");
        ArchV4PositionLocker.Lock memory created = LOCKER.getLock(first.lockId);
        require(created.owner == address(this) && created.tokenId == first.positionIdOrAmount, "v4 canary: lock");
        LOCKER.transferLockOwnership(first.lockId, provider);
        require(LOCKER.getLock(first.lockId).owner == provider, "v4 canary: lock owner");
        require(token.allowance(address(this), address(PROVISIONER)) == 0, "v4 canary: allowance");
        require(token.balanceOf(address(PROVISIONER)) == 0, "v4 canary: provisioner token");
        require(WETH.balanceOf(address(PROVISIONER)) == 0, "v4 canary: provisioner weth");
        require(token.balanceOf(address(PROVISIONER.ADAPTER())) == 0, "v4 canary: adapter token");
        require(WETH.balanceOf(address(PROVISIONER.ADAPTER())) == 0, "v4 canary: adapter weth");

        uint256 remainingTokens = token.balanceOf(address(this));
        if (remainingTokens > 0) IERC20(address(token)).safeTransfer(provider, remainingTokens);
        uint256 remainingEth = address(this).balance;
        if (remainingEth > 0) {
            (bool refunded,) = payable(provider).call{value: remainingEth}("");
            require(refunded, "v4 canary: eth refund");
        }

        TOKEN = token;
        POOL_ID = first.poolId;
        TIMED_POSITION = first.positionIdOrAmount;
        LOCK_ID = first.lockId;
        PERMANENT_POSITION = second.positionIdOrAmount;
    }
}

contract CanaryV4UserLiquidity is Script {
    uint256 private constant CANARY_VALUE = 0.00215 ether;

    function run() external {
        require(block.chainid == 46630, "v4 canary: wrong chain");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address provider = vm.addr(privateKey);
        require(provider.balance >= CANARY_VALUE + 0.005 ether, "v4 canary: balance");

        vm.startBroadcast(privateKey);
        V4UserLiquidityCanary canary = new V4UserLiquidityCanary{value: CANARY_VALUE}(provider);
        vm.stopBroadcast();

        console2.log("V4 Canary", address(canary));
        console2.log("V4 Canary Token", address(canary.TOKEN()));
        console2.log("V4 Canary Pool ID");
        console2.logBytes32(canary.POOL_ID());
        console2.log("V4 Canary Timed Position", canary.TIMED_POSITION());
        console2.log("V4 Canary Lock ID", canary.LOCK_ID());
        console2.log("V4 Canary Permanent Position", canary.PERMANENT_POSITION());
    }
}
