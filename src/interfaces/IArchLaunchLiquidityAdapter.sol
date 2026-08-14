// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

interface IArchLaunchRegistry {
    function isLaunch(address candidate) external view returns (bool);
}

/// @title IArchLaunchLiquidityAdapter
/// @notice AMM-family boundary used by versioned ArchLiquid launch contracts.
///         The caller transfers an exact token/WETH seed into a canonical pool;
///         the adapter then either time-locks or permanently custodies the LP
///         position and returns enough identity data to wire the launch token.
interface IArchLaunchLiquidityAdapter {
    struct SeedParams {
        address token;
        uint256 tokenAmount;
        uint256 wethAmount;
        address lockOwner;
        uint64 unlockTime;
        bool permanent;
    }

    struct SeedResult {
        address market;
        bytes32 poolId;
        address positionManager;
        uint256 positionIdOrAmount;
        uint256 lockId;
        uint256 tokenUsed;
        uint256 wethUsed;
    }

    function weth() external view returns (address);
    function liquidityProvisioner() external view returns (address);
    function validateSeedAmounts(uint256 tokenAmount, uint256 wethAmount) external view;
    function seed(SeedParams calldata params) external returns (SeedResult memory result);
}
