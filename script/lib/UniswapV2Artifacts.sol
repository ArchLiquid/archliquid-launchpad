// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @dev Test/deployment helper for the pinned upstream V2 creation bytecode.
///      The bytecode itself retains its upstream GPL-3.0-or-later license and
///      is documented in contracts/THIRD_PARTY_NOTICES.md.
library UniswapV2Artifacts {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant FACTORY_ARTIFACT = "vendor-artifacts/uniswap-v2/UniswapV2Factory.json";
    string internal constant ROUTER_ARTIFACT = "vendor-artifacts/uniswap-v2/UniswapV2Router02.json";

    function deployFactory(address feeToSetter) internal returns (address deployed) {
        deployed = _deploy(FACTORY_ARTIFACT, abi.encode(feeToSetter));
    }

    function deployRouter(address factory, address weth) internal returns (address deployed) {
        deployed = _deploy(ROUTER_ARTIFACT, abi.encode(factory, weth));
    }

    function _deploy(string memory artifact, bytes memory constructorArgs) private returns (address deployed) {
        string memory json = VM.readFile(artifact);
        bytes memory creationCode = VM.parseJsonBytes(json, ".bytecode");
        bytes memory initCode = bytes.concat(creationCode, constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0) && deployed.code.length > 0, "v2 artifact: deployment failed");
    }
}
