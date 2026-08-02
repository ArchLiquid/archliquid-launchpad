// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ArchBondingCurve} from "./ArchBondingCurve.sol";

/// @title ArchCurveDeployer
/// @notice Deploys ArchBondingCurve instances on the launchpad's behalf, keeping
///         the curve creation bytecode out of ArchLaunchpad (EIP-170 size).
///         Only the launchpad may deploy.
contract ArchCurveDeployer {
    address public immutable ADMIN;
    address public launchpad;

    constructor() {
        ADMIN = msg.sender;
    }

    function setLaunchpad(address launchpad_) external {
        require(msg.sender == ADMIN && launchpad == address(0) && launchpad_ != address(0), "deployer: auth");
        launchpad = launchpad_;
    }

    function deploy(
        address creator,
        ArchBondingCurve.Infra calldata infra,
        ArchBondingCurve.TokenConfig calldata t,
        ArchBondingCurve.CurveConfig calldata c
    ) external returns (address) {
        require(msg.sender == launchpad, "deployer: only launchpad");
        return address(new ArchBondingCurve(creator, infra, t, c));
    }
}
