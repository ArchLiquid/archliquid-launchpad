// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ArchAdapterPresale} from "./ArchAdapterPresale.sol";

/// @title ArchAdapterPresaleDeployer
/// @notice Isolates presale creation bytecode from the versioned launchpad.
///         The deployer can be bound to exactly one launchpad.
contract ArchAdapterPresaleDeployer {
    address public immutable ADMIN;
    address public launchpad;

    constructor() {
        ADMIN = msg.sender;
    }

    function setLaunchpad(address launchpad_) external {
        require(msg.sender == ADMIN && launchpad == address(0) && launchpad_ != address(0), "adapter deployer: auth");
        require(launchpad_.code.length > 0, "adapter deployer: invalid launchpad");
        launchpad = launchpad_;
    }

    function deploy(
        address creator,
        ArchAdapterPresale.Infra calldata infra,
        ArchAdapterPresale.TokenConfig calldata tokenConfig,
        ArchAdapterPresale.SaleConfig calldata saleConfig
    ) external returns (address) {
        require(msg.sender == launchpad, "adapter deployer: only launchpad");
        return address(new ArchAdapterPresale(creator, infra, tokenConfig, saleConfig));
    }
}
