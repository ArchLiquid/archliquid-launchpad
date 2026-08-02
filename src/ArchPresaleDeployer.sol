// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ArchPresale} from "./ArchPresale.sol";

/// @title ArchPresaleDeployer
/// @notice Deploys ArchPresale instances on the launchpad's behalf. Splitting
///         this out keeps the presale creation bytecode out of ArchLaunchpad's
///         own code, which would otherwise exceed the EIP-170 24KB contract size
///         limit. Only the launchpad may deploy, so no rogue (unregistered,
///         unexempted) presales can be minted through this primitive.
contract ArchPresaleDeployer {
    address public immutable ADMIN;
    address public launchpad;

    constructor() {
        ADMIN = msg.sender;
    }

    /// @notice Bind the launchpad once, by the deployer's admin (the deploy
    ///         script). Immutable after the first set.
    function setLaunchpad(address launchpad_) external {
        require(msg.sender == ADMIN && launchpad == address(0) && launchpad_ != address(0), "deployer: auth");
        launchpad = launchpad_;
    }

    function deploy(
        address creator,
        ArchPresale.Infra calldata infra,
        ArchPresale.TokenConfig calldata t,
        ArchPresale.SaleConfig calldata s
    ) external returns (address) {
        require(msg.sender == launchpad, "deployer: only launchpad");
        return address(new ArchPresale(creator, infra, t, s));
    }
}
