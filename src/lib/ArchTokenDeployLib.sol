// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";

/// @title ArchTokenDeployLib
/// @notice Deploys ArchToken instances via CREATE2. This is a `public` (external,
///         delegatecall-linked) library, so the ArchToken creation bytecode lives
///         in the library's own deployed code, NOT inlined into every caller.
///         That keeps ArchPresale and ArchBondingCurve creation code small
///         enough that their deployers stay under the EIP-170 24KB limit.
///
///         Because the library is delegatecalled, `address(this)` inside `deploy`
///         is the CALLER (the presale/curve/factory), so the CREATE2 is executed
///         from the caller's address: the resulting token address and its
///         immutable FACTORY (= msg.sender in the ArchToken constructor) are
///         identical to a direct `new ArchToken{salt}` in the caller. No wiring
///         or address semantics change.
library ArchTokenDeployLib {
    function deploy(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint16 taxBps,
        IERC20 stock,
        ArchToken.DexConfig memory dex,
        address payable treasury,
        address keeper,
        uint16 creatorFeeBps,
        address creator,
        bytes32 salt
    ) public returns (ArchToken) {
        return new ArchToken{salt: salt}(
            name, symbol, totalSupply, taxBps, stock, dex, treasury, keeper, creatorFeeBps, creator
        );
    }
}
