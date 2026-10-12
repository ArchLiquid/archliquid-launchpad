// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {ArchAdapterTokenFactory} from "../src/ArchAdapterTokenFactory.sol";
import {IArchLaunchLiquidityAdapter} from "../src/interfaces/IArchLaunchLiquidityAdapter.sol";
import {PoolKey} from "../src/interfaces/IUniswapV4.sol";
import {V4CanaryValidation} from "./lib/V4CanaryValidation.sol";

interface IV4CanaryPermit2Allowances {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice One-transaction bounded-value check of a selected fresh V4 release.
///         Constructor failure reverts token creation and both liquidity
///         operations atomically. Existing release addresses are never assumed.
contract V4UserLiquidityCanary {
    using SafeERC20 for IERC20;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant SUPPLY = 1_000_000e18;
    uint256 private constant TOKEN_AMOUNT = 100_000e18;
    uint256 private constant ETH_AMOUNT = 0.001 ether;
    address private immutable _provisioner;

    ArchToken public immutable TOKEN;
    bytes32 public immutable POOL_ID;
    uint256 public immutable TIMED_POSITION;
    uint256 public immutable LOCK_ID;
    uint256 public immutable PERMANENT_POSITION;

    receive() external payable {
        require(msg.sender == _provisioner, "v4 canary: refund sender");
    }

    constructor(address provider, ArchAdapterTokenFactory factory, IERC20 stock, uint256 maximumFactoryFee) payable {
        require(provider != address(0) && msg.sender == provider, "v4 canary: provider");
        // Recheck at execution time: another user can consume the fresh factory
        // after the script's preflight but before this transaction is included.
        V4CanaryValidation.Release memory release = V4CanaryValidation.validate(factory, stock, maximumFactoryFee);
        require(msg.value == release.value, "v4 canary: value");
        _provisioner = address(release.provisioner);

        uint256 provisionerWethBefore = release.weth.balanceOf(address(release.provisioner));
        uint256 adapterWethBefore = release.weth.balanceOf(address(release.adapter));
        ArchToken token = ArchToken(
            payable(factory.createToken{value: release.factoryFee}(
                    ArchAdapterTokenFactory.TokenParams({
                        name: "Arch V4 Liquidity Canary",
                        symbol: "AV4LC",
                        totalSupply: SUPPLY,
                        taxBps: 300,
                        stock: stock,
                        creatorFeeBps: 0
                    }),
                    ArchAdapterTokenFactory.LiquidityParams({
                        enabled: false, lpPct: 0, poolFee: 0, burnLp: false, lockDuration: 0
                    })
                ))
        );
        IERC20(address(token)).forceApprove(address(release.provisioner), 2 * TOKEN_AMOUNT);
        IArchLaunchLiquidityAdapter.SeedResult memory first = release.provisioner.addLiquidity{value: ETH_AMOUNT}(
            token, TOKEN_AMOUNT, address(0), 1, type(uint160).max, 30 days, false
        );
        (uint160 sqrtPriceX96,,,) = release.stateView.getSlot0(first.poolId);
        IArchLaunchLiquidityAdapter.SeedResult memory second = release.provisioner.addLiquidity{value: ETH_AMOUNT}(
            token, TOKEN_AMOUNT, first.market, sqrtPriceX96, sqrtPriceX96, 0, true
        );

        _validatePositions(release, token, first, second);
        release.locker.transferLockOwnership(first.lockId, provider);
        require(release.locker.getLock(first.lockId).owner == provider, "v4 canary: lock owner");
        require(factory.tokenCount() == 1 && factory.allTokens(0) == address(token), "v4 canary: factory result");
        require(token.allowance(address(this), address(release.provisioner)) == 0, "v4 canary: allowance");
        require(token.balanceOf(address(release.provisioner)) == 0, "v4 canary: provisioner token");
        require(token.balanceOf(address(release.adapter)) == 0, "v4 canary: adapter token");
        require(
            release.weth.balanceOf(address(release.provisioner)) == provisionerWethBefore, "v4 canary: provisioner weth"
        );
        require(release.weth.balanceOf(address(release.adapter)) == adapterWethBefore, "v4 canary: adapter weth");
        require(
            token.allowance(address(release.provisioner), address(release.adapter)) == 0
                && release.weth.allowance(address(release.provisioner), address(release.adapter)) == 0,
            "v4 canary: provisioner approvals"
        );
        address permit2 = address(release.adapter.PERMIT2());
        require(
            token.allowance(address(release.adapter), permit2) == 0
                && release.weth.allowance(address(release.adapter), permit2) == 0,
            "v4 canary: adapter approvals"
        );

        (uint160 tokenPermitAmount,,) = IV4CanaryPermit2Allowances(permit2)
            .allowance(address(release.adapter), address(token), address(release.positionManager));
        (uint160 wethPermitAmount,,) = IV4CanaryPermit2Allowances(permit2)
            .allowance(address(release.adapter), address(release.weth), address(release.positionManager));
        require(tokenPermitAmount == 0 && wethPermitAmount == 0, "v4 canary: permit2 approvals");

        uint256 remainingTokens = token.balanceOf(address(this));
        require(remainingTokens == SUPPLY - first.tokenUsed - second.tokenUsed, "v4 canary: remaining tokens");
        if (remainingTokens > 0) IERC20(address(token)).safeTransfer(provider, remainingTokens);
        uint256 remainingEth = address(this).balance;
        require(remainingEth == 2 * ETH_AMOUNT - first.wethUsed - second.wethUsed, "v4 canary: remaining eth");
        if (remainingEth > 0) {
            (bool refunded,) = payable(provider).call{value: remainingEth}("");
            require(refunded, "v4 canary: eth refund");
        }
        require(token.balanceOf(address(this)) == 0 && address(this).balance == 0, "v4 canary: canary residue");

        TOKEN = token;
        POOL_ID = first.poolId;
        TIMED_POSITION = first.positionIdOrAmount;
        LOCK_ID = first.lockId;
        PERMANENT_POSITION = second.positionIdOrAmount;
    }

    function _validatePositions(
        V4CanaryValidation.Release memory release,
        ArchToken token,
        IArchLaunchLiquidityAdapter.SeedResult memory first,
        IArchLaunchLiquidityAdapter.SeedResult memory second
    ) private view {
        address manager = address(release.adapter.POOL_MANAGER());
        require(
            token.wired() && token.liquidityProvisioner() == address(release.provisioner), "v4 canary: token wiring"
        );
        require(token.marketPairCount() == 1 && token.isMarketPair(manager), "v4 canary: market");
        require(first.market == manager && second.market == manager, "v4 canary: manager");
        require(
            first.positionManager == address(release.positionManager)
                && second.positionManager == address(release.positionManager),
            "v4 canary: result position manager"
        );
        require(
            first.positionIdOrAmount > 0 && second.positionIdOrAmount > 0
                && first.positionIdOrAmount != second.positionIdOrAmount,
            "v4 canary: position ids"
        );
        bool tokenIs0 = address(token) < address(release.weth);
        PoolKey memory key = PoolKey({
            currency0: tokenIs0 ? address(token) : address(release.weth),
            currency1: tokenIs0 ? address(release.weth) : address(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        bytes32 poolId = keccak256(abi.encode(key));
        require(first.poolId == poolId && second.poolId == poolId, "v4 canary: pool mismatch");
        _validatePosition(release, first, poolId);
        _validatePosition(release, second, poolId);
        require(
            release.positionManager.ownerOf(first.positionIdOrAmount) == address(release.locker),
            "v4 canary: lock custody"
        );
        require(release.positionManager.ownerOf(second.positionIdOrAmount) == DEAD, "v4 canary: burn custody");
        require(second.lockId == type(uint256).max, "v4 canary: permanent lock id");
        ArchV4PositionLocker.Lock memory created = release.locker.getLock(first.lockId);
        require(
            created.owner == address(this) && created.tokenId == first.positionIdOrAmount
                && created.unlockTime == block.timestamp + 30 days && !created.withdrawn
                && created.currency0 == key.currency0 && created.currency1 == key.currency1
                && created.hooks == address(0),
            "v4 canary: lock"
        );
    }

    function _validatePosition(
        V4CanaryValidation.Release memory release,
        IArchLaunchLiquidityAdapter.SeedResult memory result,
        bytes32 expectedPoolId
    ) private view {
        require(
            result.tokenUsed > 0 && result.tokenUsed <= TOKEN_AMOUNT && result.wethUsed > 0
                && result.wethUsed <= ETH_AMOUNT,
            "v4 canary: consumption"
        );
        (PoolKey memory actualKey,) = release.positionManager.getPoolAndPositionInfo(result.positionIdOrAmount);
        require(keccak256(abi.encode(actualKey)) == expectedPoolId, "v4 canary: position pool");
        require(
            release.positionManager.getPositionLiquidity(result.positionIdOrAmount) > 0, "v4 canary: empty position"
        );
        require(release.positionManager.subscriber(result.positionIdOrAmount) == address(0), "v4 canary: subscriber");
    }
}

contract CanaryV4UserLiquidity is Script {
    uint256 private constant GAS_RESERVE = 0.005 ether;

    function run() external {
        require(block.chainid == 46630, "v4 canary: wrong chain");
        // Required settings deliberately have no historical-address fallback.
        ArchAdapterTokenFactory factory = ArchAdapterTokenFactory(payable(vm.envAddress("TESTNET_V4_TOKEN_FACTORY")));
        IERC20 stock = IERC20(vm.envAddress("TESTNET_AMM_STOCK"));
        uint256 maximumFactoryFee = vm.envOr("TESTNET_V4_CANARY_MAX_FACTORY_FEE", uint256(0.001 ether));
        V4CanaryValidation.Release memory release = V4CanaryValidation.validate(factory, stock, maximumFactoryFee);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address provider = vm.addr(privateKey);
        require(provider.balance >= release.value + GAS_RESERVE, "v4 canary: balance");

        console2.log("V4 Canary Target Factory", address(factory));
        console2.log("V4 Canary Target Adapter", address(release.adapter));
        console2.log("V4 Canary Target Provisioner", address(release.provisioner));
        console2.log("V4 Canary Stock", address(stock));
        console2.log("V4 Canary Factory Fee", release.factoryFee);
        console2.log("V4 Canary Maximum Factory Fee", maximumFactoryFee);
        console2.log("V4 Canary Transaction Value", release.value);

        vm.startBroadcast(privateKey);
        V4UserLiquidityCanary canary =
            new V4UserLiquidityCanary{value: release.value}(provider, factory, stock, maximumFactoryFee);
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
