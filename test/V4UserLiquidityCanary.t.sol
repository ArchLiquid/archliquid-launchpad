// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchAdapterTokenFactory} from "../src/ArchAdapterTokenFactory.sol";
import {CanaryV4UserLiquidity, V4UserLiquidityCanary} from "../script/CanaryV4UserLiquidity.s.sol";
import {V4CanaryValidation} from "../script/lib/V4CanaryValidation.sol";

contract V4CanaryValidationHarness {
    function validate(address factory, address stock, uint256 maximumFactoryFee)
        external
        view
        returns (uint256 fee, uint256 value, address adapter, address provisioner)
    {
        V4CanaryValidation.Release memory release = V4CanaryValidation.validate(
            ArchAdapterTokenFactory(payable(factory)), IERC20(stock), maximumFactoryFee
        );
        return (release.factoryFee, release.value, address(release.adapter), address(release.provisioner));
    }
}

/// @dev Mocked getters isolate preflight failures. Real liquidity accounting
///      and full constructor rollback are covered by V4UserLiquidityCanaryFork.
contract V4UserLiquidityCanaryTest is Test {
    uint256 private constant MAX_FEE = 0.001 ether;
    uint256 private constant FEE = 0.0004 ether;
    address private factory = makeAddr("canary factory");
    address private adapter = makeAddr("canary adapter");
    address private provisioner = makeAddr("canary provisioner");
    address private weth = makeAddr("canary weth");
    address private stock = makeAddr("canary stock");
    address private poolManager = makeAddr("canary pool manager");
    address private positionManager = makeAddr("canary position manager");
    address private stateView = makeAddr("canary state view");
    address private permit2 = makeAddr("canary permit2");
    address private locker = makeAddr("canary locker");
    address private swapRouter = makeAddr("canary swap router");
    address private registry = makeAddr("canary registry");
    address private executor = makeAddr("canary executor");
    V4CanaryValidationHarness private harness;

    function setUp() public {
        vm.chainId(46630);
        vm.deal(address(this), 1 ether);
        harness = new V4CanaryValidationHarness();
        address[13] memory dependencies = [
            factory,
            adapter,
            provisioner,
            weth,
            stock,
            poolManager,
            positionManager,
            stateView,
            permit2,
            locker,
            swapRouter,
            registry,
            executor
        ];
        for (uint256 i; i < dependencies.length; i++) {
            vm.etch(dependencies[i], hex"00");
        }

        _mockUint(factory, "tokenCount()", 0);
        _mockUint(factory, "FEE()", FEE);
        _mockAddress(factory, "LIQUIDITY_ADAPTER()", adapter);
        _mockAddress(factory, "WETH()", weth);
        _mockAddress(factory, "SWAP_ROUTER()", swapRouter);
        _mockUint(factory, "TOKEN_POOL_FEE()", 3000);
        _mockUint(factory, "STOCK_POOL_FEE()", 0);
        _mockAddress(factory, "STOCK_REGISTRY()", registry);
        _mockUint(adapter, "launchersBound()", 1);
        _mockAddress(adapter, "tokenFactory()", factory);
        _mockAddress(adapter, "liquidityProvisioner()", provisioner);
        _mockAddress(adapter, "weth()", weth);
        _mockAddress(adapter, "POOL_MANAGER()", poolManager);
        _mockAddress(adapter, "POSITION_MANAGER()", positionManager);
        _mockAddress(adapter, "STATE_VIEW()", stateView);
        _mockAddress(adapter, "PERMIT2()", permit2);
        _mockAddress(adapter, "LOCKER()", locker);
        _mockAddress(provisioner, "ADAPTER()", adapter);
        _mockAddress(provisioner, "WETH()", weth);
        _mockAddress(positionManager, "poolManager()", poolManager);
        _mockAddress(positionManager, "permit2()", permit2);
        _mockAddress(stateView, "poolManager()", poolManager);
        _mockAddress(locker, "POSITION_MANAGER()", positionManager);
        _mockAddress(locker, "POOL_MANAGER()", poolManager);
        _mockAddress(swapRouter, "POOL_MANAGER()", poolManager);
        _mockAddress(swapRouter, "WETH()", weth);
        vm.mockCall(locker, abi.encodeWithSignature("feeExempt(address)", adapter), abi.encode(true));
        vm.mockCall(registry, abi.encodeWithSignature("isApproved(address)", stock), abi.encode(true));
        _mockAddress(registry, "stockSwapExecutor()", executor);
    }

    function test_coherentReleaseDerivesDependenciesAndDynamicValue() public view {
        (uint256 fee, uint256 value, address actualAdapter, address actualProvisioner) =
            harness.validate(factory, stock, MAX_FEE);
        assertEq(fee, FEE);
        assertEq(value, FEE + 0.002 ether);
        assertEq(actualAdapter, adapter);
        assertEq(actualProvisioner, provisioner);
    }

    function testFuzz_feeIsBoundedAndAddedToFixedSeed(uint256 fee) public {
        fee = bound(fee, 0, MAX_FEE);
        _mockUint(factory, "FEE()", fee);
        (uint256 actualFee, uint256 value,,) = harness.validate(factory, stock, fee);
        assertEq(actualFee, fee);
        assertEq(value, fee + 0.002 ether);
        assertLe(value, 0.003 ether);
    }

    function test_wrongChainRejectsBeforeDependencyReads() public {
        vm.chainId(1);
        _expectFailure("v4 canary: wrong chain");
    }

    function test_scriptWrongChainRejectsBeforeReadingEnvironment() public {
        vm.chainId(1);
        CanaryV4UserLiquidity script = new CanaryV4UserLiquidity();
        vm.expectRevert("v4 canary: wrong chain");
        script.run();
    }

    function test_feeCeilingCannotRaiseHardValueLimit() public {
        vm.expectRevert("v4 canary: excessive fee ceiling");
        harness.validate(factory, stock, MAX_FEE + 1);
    }

    function test_factoryFeeAboveSelectedCeilingRejects() public {
        vm.expectRevert("v4 canary: factory fee exceeds ceiling");
        harness.validate(factory, stock, FEE - 1);
    }

    function test_missingFactoryRejects() public {
        vm.etch(factory, "");
        _expectFailure("v4 canary: factory missing");
    }

    function test_missingStockRejects() public {
        vm.etch(stock, "");
        _expectFailure("v4 canary: stock missing");
    }

    function test_nonfreshFactoryRejects() public {
        _mockUint(factory, "tokenCount()", 1);
        _expectFailure("v4 canary: release not fresh");
    }

    function test_missingAdapterRejects() public {
        vm.etch(adapter, "");
        _expectFailure("v4 canary: adapter missing");
    }

    function test_unboundAdapterRejects() public {
        _mockUint(adapter, "launchersBound()", 0);
        _expectFailure("v4 canary: adapter not bound");
    }

    function test_wrongFactoryBindingRejects() public {
        _mockAddress(adapter, "tokenFactory()", address(0xbad));
        _expectFailure("v4 canary: factory binding");
    }

    function test_missingProvisionerRejects() public {
        vm.etch(provisioner, "");
        _expectFailure("v4 canary: provisioner missing");
    }

    function test_wrongProvisionerBindingRejects() public {
        _mockAddress(provisioner, "ADAPTER()", address(0xbad));
        _expectFailure("v4 canary: provisioner binding");
    }

    function test_missingWethRejects() public {
        vm.etch(weth, "");
        _expectFailure("v4 canary: weth missing");
    }

    function test_stockCannotBeWeth() public {
        vm.expectRevert("v4 canary: stock is weth");
        harness.validate(factory, weth, MAX_FEE);
    }

    function test_wrongAdapterWethRejects() public {
        _mockAddress(adapter, "weth()", stock);
        _expectFailure("v4 canary: adapter weth");
    }

    function test_wrongProvisionerWethRejects() public {
        _mockAddress(provisioner, "WETH()", stock);
        _expectFailure("v4 canary: provisioner weth");
    }

    function test_missingPoolManagerRejects() public {
        vm.etch(poolManager, "");
        _expectFailure("v4 canary: pool manager missing");
    }

    function test_missingPositionManagerRejects() public {
        vm.etch(positionManager, "");
        _expectFailure("v4 canary: position manager missing");
    }

    function test_missingStateViewRejects() public {
        vm.etch(stateView, "");
        _expectFailure("v4 canary: state view missing");
    }

    function test_missingPermit2Rejects() public {
        vm.etch(permit2, "");
        _expectFailure("v4 canary: permit2 missing");
    }

    function test_missingLockerRejects() public {
        vm.etch(locker, "");
        _expectFailure("v4 canary: locker missing");
    }

    function test_wrongPositionManagerPoolRejects() public {
        _mockAddress(positionManager, "poolManager()", address(0xbad));
        _expectFailure("v4 canary: position manager pool");
    }

    function test_wrongStateViewPoolRejects() public {
        _mockAddress(stateView, "poolManager()", address(0xbad));
        _expectFailure("v4 canary: state view pool");
    }

    function test_wrongPositionManagerPermit2Rejects() public {
        _mockAddress(positionManager, "permit2()", address(0xbad));
        _expectFailure("v4 canary: position manager permit2");
    }

    function test_wrongLockerManagerRejects() public {
        _mockAddress(locker, "POSITION_MANAGER()", address(0xbad));
        _expectFailure("v4 canary: locker manager");
    }

    function test_wrongLockerPoolRejects() public {
        _mockAddress(locker, "POOL_MANAGER()", address(0xbad));
        _expectFailure("v4 canary: locker pool");
    }

    function test_missingLockerExemptionRejects() public {
        vm.mockCall(locker, abi.encodeWithSignature("feeExempt(address)", adapter), abi.encode(false));
        _expectFailure("v4 canary: locker fee exemption");
    }

    function test_missingSwapRouterRejects() public {
        vm.etch(swapRouter, "");
        _expectFailure("v4 canary: swap router missing");
    }

    function test_wrongSwapPoolRejects() public {
        _mockAddress(swapRouter, "POOL_MANAGER()", address(0xbad));
        _expectFailure("v4 canary: swap pool");
    }

    function test_wrongSwapWethRejects() public {
        _mockAddress(swapRouter, "WETH()", stock);
        _expectFailure("v4 canary: swap weth");
    }

    function test_wrongTokenFeePolicyRejects() public {
        _mockUint(factory, "TOKEN_POOL_FEE()", 500);
        _expectFailure("v4 canary: factory fee policy");
    }

    function test_wrongStockFeePolicyRejects() public {
        _mockUint(factory, "STOCK_POOL_FEE()", 3000);
        _expectFailure("v4 canary: factory fee policy");
    }

    function test_missingRegistryRejects() public {
        vm.etch(registry, "");
        _expectFailure("v4 canary: registry missing");
    }

    function test_unapprovedStockRejects() public {
        vm.mockCall(registry, abi.encodeWithSignature("isApproved(address)", stock), abi.encode(false));
        _expectFailure("v4 canary: stock not approved");
    }

    function test_missingExecutorRejects() public {
        _mockAddress(registry, "stockSwapExecutor()", address(0));
        _expectFailure("v4 canary: executor missing");
    }

    function test_executorWithoutCodeRejects() public {
        vm.etch(executor, "");
        _expectFailure("v4 canary: executor missing");
    }

    function test_constructorRechecksFreshnessAfterSuccessfulPreflight() public {
        harness.validate(factory, stock, MAX_FEE);
        _mockUint(factory, "tokenCount()", 1);
        vm.expectRevert("v4 canary: release not fresh");
        new V4UserLiquidityCanary{value: FEE + 0.002 ether}(
            address(this), ArchAdapterTokenFactory(payable(factory)), IERC20(stock), MAX_FEE
        );
    }

    function test_constructorRejectsIncorrectValueBeforeTokenCreation() public {
        vm.expectRevert("v4 canary: value");
        new V4UserLiquidityCanary{value: FEE + 0.002 ether + 1}(
            address(this), ArchAdapterTokenFactory(payable(factory)), IERC20(stock), MAX_FEE
        );
    }

    function test_constructorRejectsSubstitutedProvider() public {
        vm.expectRevert("v4 canary: provider");
        new V4UserLiquidityCanary{value: FEE + 0.002 ether}(
            address(0xbad), ArchAdapterTokenFactory(payable(factory)), IERC20(stock), MAX_FEE
        );
    }

    function _expectFailure(string memory reason) private {
        vm.expectRevert(bytes(reason));
        harness.validate(factory, stock, MAX_FEE);
    }

    function _mockAddress(address target, string memory signature, address value) private {
        vm.mockCall(target, abi.encodeWithSignature(signature), abi.encode(value));
    }

    function _mockUint(address target, string memory signature, uint256 value) private {
        vm.mockCall(target, abi.encodeWithSignature(signature), abi.encode(value));
    }
}
