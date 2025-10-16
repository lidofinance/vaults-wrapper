// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

interface IOperatorGrid {
    struct TierParams {
        uint256 shareLimit;
        uint256 reserveRatioBP;
        uint256 forcedRebalanceThresholdBP;
        uint256 infraFeeBP;
        uint256 liquidityFeeBP;
        uint256 reservationFeeBP;
    }

    struct Tier {
        address operator;
        uint96 shareLimit;
        uint96 liabilityShares;
        uint16 reserveRatioBP;
        uint16 forcedRebalanceThresholdBP;
        uint16 infraFeeBP;
        uint16 liquidityFeeBP;
        uint16 reservationFeeBP;
    }

    function tier(uint256 _tierId) external view returns (Tier memory);

    function effectiveShareLimit(address _vault) external view returns (uint256);

    function isVaultInJail(address _vault) external view returns (bool);

    function vaultTierInfo(address _vault)
        external
        view
        returns (
            address nodeOperator,
            uint256 tierId,
            uint256 shareLimit,
            uint256 reserveRatioBP,
            uint256 forcedRebalanceThresholdBP,
            uint256 infraFeeBP,
            uint256 liquidityFeeBP,
            uint256 reservationFeeBP
        )
    ;

    function alterTiers(uint256[] calldata _tierIds, TierParams[] calldata _tierParams) external;
}
