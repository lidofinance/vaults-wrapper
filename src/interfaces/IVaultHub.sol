// SPDX-License-Identifier: MIT
pragma solidity >= 0.5.0;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

uint256 constant DOUBLE_CACHE_LENGTH = 2;

library DoubleRefSlotCache {
    struct Int104WithCache {
        int104 value;
        int104 valueOnRefSlot;
        uint48 refSlot;
    }
}

interface IVaultHub is IAccessControl {
    struct VaultConnection {
        // ### 1st slot
        /// @notice address of the vault owner
        address owner;
        /// @notice maximum number of stETH shares that can be minted by vault owner
        uint96 shareLimit;
        // ### 2nd slot
        /// @notice index of the vault in the list of vaults. Indexes are not guaranteed to be stable.
        /// @dev vaultIndex is always greater than 0
        uint96 vaultIndex;
        /// @notice if true, vault is disconnected and fee is not accrued
        uint48 disconnectInitiatedTs;
        /// @notice share of ether that is locked on the vault as an additional reserve
        /// e.g RR=30% means that for 1stETH minted 1/(1-0.3)=1.428571428571428571 ETH is locked on the vault
        uint16 reserveRatioBP;
        /// @notice if vault's reserve decreases to this threshold, it should be force rebalanced
        uint16 forcedRebalanceThresholdBP;
        /// @notice infra fee in basis points
        uint16 infraFeeBP;
        /// @notice liquidity fee in basis points
        uint16 liquidityFeeBP;
        /// @notice reservation fee in basis points
        uint16 reservationFeeBP;
        /// @notice if true, vault owner manually paused the beacon chain deposits
        bool isBeaconDepositsManuallyPaused;
    }
    /// 24 bits gap

    struct VaultRecord {
        // ### 1st slot
        /// @notice latest report for the vault
        Report report;
        // ### 2nd slot
        /// @notice max number of shares that was minted by the vault in current Oracle period
        /// (used to calculate the locked value on the vault)
        uint96 maxLiabilityShares;
        /// @notice liability shares of the vault
        uint96 liabilityShares;
        // ### 3rd and 4th slots
        /// @notice inOutDelta of the vault (all deposits - all withdrawals)
        Int104WithCache[2] inOutDelta; // 2 is the constant DOUBLE_CACHE_LENGTH from RefSlotCache.sol
        // ### 5th slot
        /// @notice the minimal value that the reserve part of the locked can be
        uint128 minimalReserve;
        /// @notice part of liability shares reserved to be burnt as Lido core redemptions
        uint128 redemptionShares;
        // ### 6th slot
        /// @notice cumulative value for Lido fees that accrued on the vault
        uint128 cumulativeLidoFees;
        /// @notice cumulative value for Lido fees that were settled on the vault
        uint128 settledLidoFees;
    }

    struct Report {
        /// @notice total value of the vault
        uint104 totalValue;
        /// @notice inOutDelta of the report
        int104 inOutDelta;
        /// @notice timestamp (in seconds)
        uint48 timestamp;
    }

    struct Int104WithCache {
        int104 value;
        int104 valueOnRefSlot;
        uint48 refSlot;
    }

    function CONNECT_DEPOSIT() external view returns (uint256);

    function fund(address vault) external payable;
    // function withdraw(address vault, address recipient, uint256 etherAmount) external;
    function totalValue(address vault) external view returns (uint256);
    function withdrawableValue(address vault) external view returns (uint256);
    function requestValidatorExit(address vault, bytes calldata pubkeys) external;
    function triggerValidatorWithdrawals(
        address vault,
        bytes calldata pubkeys,
        uint64[] calldata amounts,
        address refundRecipient
    ) external payable;
    function mintShares(address _vault, address _recipient, uint256 _amountOfShares) external;
    function vaultConnection(address _vault) external view returns (VaultConnection memory);
    function vaultRecord(address _vault) external view returns (VaultRecord memory);
    function maxLockableValue(address _vault) external view returns (uint256);
    function isReportFresh(address _vault) external view returns (bool);
    function transferVaultOwnership(address _vault, address _newOwner) external;

    function applyVaultReport(
        address _vault,
        uint256 _reportTimestamp,
        uint256 _reportTotalValue,
        int256 _reportInOutDelta,
        uint256 _reportCumulativeLidoFees,
        uint256 _reportLiabilityShares,
        uint256 _reportSlashingReserve
    ) external;

    // -----------------------------
    //           ERRORS
    // -----------------------------

    event BadDebtSocialized(address indexed vaultDonor, address indexed vaultAcceptor, uint256 badDebtShares);
    event BadDebtWrittenOffToBeInternalized(address indexed vault, uint256 badDebtShares);

    error ZeroBalance();

    /**
     * @notice Thrown when attempting to rebalance more ether than the current total value of the vault
     * @param totalValue Current total value of the vault
     * @param rebalanceAmount Amount attempting to rebalance (in ether)
     */
    error RebalanceAmountExceedsTotalValue(uint256 totalValue, uint256 rebalanceAmount);

    /**
     * @notice Thrown when attempting to withdraw more ether than the available value of the vault
     * @param vault The address of the vault
     * @param withdrawable The available value of the vault
     * @param requested The amount attempting to withdraw
     */
    error AmountExceedsWithdrawableValue(address vault, uint256 withdrawable, uint256 requested);

    error AlreadyHealthy(address vault);
    error VaultMintingCapacityExceeded(
        address vault, uint256 totalValue, uint256 liabilityShares, uint256 newRebalanceThresholdBP
    );
    error InsufficientSharesToBurn(address vault, uint256 amount);
    error ShareLimitExceeded(address vault, uint256 expectedSharesAfterMint, uint256 shareLimit);
    error AlreadyConnected(address vault, uint256 index);
    error NotConnectedToHub(address vault);
    error NotAuthorized();
    error ZeroAddress();
    error ZeroArgument();
    error InvalidBasisPoints(uint256 valueBP, uint256 maxValueBP);
    error ShareLimitTooHigh(uint256 shareLimit, uint256 maxShareLimit);
    error InsufficientValueToMint(address vault, uint256 maxLockableValue);
    error NoLiabilitySharesShouldBeLeft(address vault, uint256 liabilityShares);
    error CodehashNotAllowed(address vault, bytes32 codehash);
    error InvalidFees(address vault, uint256 newFees, uint256 oldFees);
    error VaultOssified(address vault);
    error VaultInsufficientBalance(address vault, uint256 currentBalance, uint256 expectedBalance);
    error VaultReportStale(address vault);
    error PDGNotDepositor(address vault);
    error ZeroCodehash();
    error VaultHubNotPendingOwner(address vault);
    error UnhealthyVaultCannotDeposit(address vault);
    error VaultIsDisconnecting(address vault);
    error VaultHasUnsettledObligations(address vault, uint256 unsettledObligations, uint256 allowedUnsettled);
    error PartialValidatorWithdrawalNotAllowed();
    error ForcedValidatorExitNotAllowed();
    error NoBadDebtToWriteOff(address vault, uint256 totalValueShares, uint256 liabilityShares);
    error BadDebtSocializationNotAllowed();

    // PausableUntil errors
    error ZeroPauseDuration();
    error PausedExpected();
    error ResumedExpected();
    error PauseUntilMustBeInFuture();
}
