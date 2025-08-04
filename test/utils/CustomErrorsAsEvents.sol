// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @title CustomErrorsAsEvents
 * @notice This contract contains all custom errors from the codebase converted to events
 * @dev Auto-generated from Solidity contracts
 */
contract CustomErrorsAsEvents {

    // From: contracts/0.8.25/ValidatorExitDelayVerifier.sol
    error RootNotFound();
    error InvalidGIndex();
    error InvalidBlockHeader();
    error UnsupportedSlot(uint64);
    error InvalidPivotSlot();
    error InvalidPerHistoricalRootSlot();
    error ZeroLidoLocatorAddress();
    error ExitIsNotEligibleOnProvableBeaconBlock(uint256, uint256);
    error InvalidCapellaSlot();

    // From: contracts/0.8.25/utils/Confirmations.sol
    error ConfirmExpiryOutOfBounds();
    error SenderNotMember();
    error ZeroConfirmingRoles();

    // From: contracts/0.8.25/utils/V3TemporaryAdmin.sol
    error ZeroAddress();
    error ZeroLidoLocator();
    error ZeroBeacon();
    error ZeroStakingRouter();
    error ZeroEvmScriptExecutor();
    error ZeroVaultHubAdapter();
    error CsmModuleNotFound();
    error SetupAlreadyCompleted();

    // From: contracts/0.8.25/vaults/LazyOracle.sol
    error AdminCannotBeZero();
    error NotAuthorized();
    error InvalidProof();
    error UnderflowInTotalValueCalculation();
    error TotalValueTooLarge();
    error VaultReportIsFreshEnough();

    // From: src/interfaces/IDashboard.sol
    error ExceedsWithdrawable(uint256 amount, uint256 withdrawableValue);
    error ExceedsMintingCapacity(uint256 requestedShares, uint256 remainingShares);
    error EthTransferFailed(address recipient, uint256 amount);
    error ConnectedToVaultHub();
    error TierChangeNotConfirmed();
    error DashboardNotAllowed();
    error FeeValueExceed100Percent();
    error IncreasedOverLimit();
    error InvalidatedAdjustmentVote(uint256 currentAdjustment, uint256 currentAtPropositionAdjustment);
    error SameAdjustment();
    error SameRecipient();
    error ReportStale();
    error AdjustmentNotReported();
    error AdjustmentNotSettled();
    error VaultQuarantined();
    error NonProxyCallsForbidden();
    error AlreadyInitialized();
    // error ZeroArgument(); // Already defined
    // error ZeroAddress(); // Already defined
    // error ConfirmExpiryOutOfBounds();
    // error SenderNotMember();
    // error ZeroConfirmingRoles();

    // From: src/interfaces/IVaultFactory.sol
    // error ZeroArgument(string argument); // Similar to existing ZeroArgument
    // error InsufficientFunds(); // Already defined

    // From: src/interfaces/IVaultHub.sol
    // error ZeroBalance(); // Already defined
    error RebalanceAmountExceedsTotalValue(uint256 totalValue, uint256 rebalanceAmount);
    error AmountExceedsWithdrawableValue(address vault, uint256 withdrawable, uint256 requested);
    error AlreadyHealthy(address vault);
    error VaultMintingCapacityExceeded(address vault, uint256 totalValue, uint256 liabilityShares, uint256 newRebalanceThresholdBP);
    error InsufficientSharesToBurn(address vault, uint256 amount);
    error ShareLimitExceeded(address vault, uint256 expectedSharesAfterMint, uint256 shareLimit);
    error AlreadyConnected(address vault, uint256 index);
    error NotConnectedToHub(address vault);
    // error NotAuthorized(); // Already defined
    // error ZeroAddress(); // Already defined
    // error ZeroArgument(); // Already defined
    error InvalidBasisPoints(uint256 valueBP, uint256 maxValueBP);
    error ShareLimitTooHigh(uint256 shareLimit, uint256 maxShareLimit);
    error InsufficientValueToMint(address vault, uint256 maxLockableValue);
    error NoLiabilitySharesShouldBeLeft(address vault, uint256 liabilityShares);
    error CodehashNotAllowed(address vault, bytes32 codehash);
    error InvalidFees(address vault, uint256 newFees, uint256 oldFees);
    // error VaultOssified(address vault); // Similar to existing VaultOssified
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
    // error ZeroPauseDuration(); // Already defined
    // error PausedExpected(); // Already defined
    // error ResumedExpected(); // Already defined
    // error PauseUntilMustBeInFuture(); // Already defined

    // From: contracts/0.8.25/vaults/OperatorGrid.sol
    // error NotAuthorized(string, address);
    error ZeroArgument(string);
    error GroupExists();
    error GroupNotExists();
    error GroupLimitExceeded();
    error NodeOperatorNotExists();
    error TierLimitExceeded();
    error TierNotExists();
    error TierAlreadySet();
    error TierNotInOperatorGroup();
    error CannotChangeToDefaultTier();
    error ReserveRatioTooHigh(uint256, uint256, uint256);
    error ForcedRebalanceThresholdTooHigh(uint256, uint256, uint256);
    error InfraFeeTooHigh(uint256, uint256, uint256);
    error LiquidityFeeTooHigh(uint256, uint256, uint256);
    error ReservationFeeTooHigh(uint256, uint256, uint256);
    error ArrayLengthMismatch();
    error RequestedShareLimitTooHigh(uint256, uint256);

    // From: contracts/0.8.25/vaults/StakingVault.sol
    error InsufficientBalance(uint256, uint256);
    error TransferFailed(address, uint256);
    error NewDepositorSameAsPrevious();
    error BeaconChainDepositsAlreadyPaused();
    error BeaconChainDepositsAlreadyResumed();
    error BeaconChainDepositsOnPause();
    error SenderNotDepositor();
    error SenderNotNodeOperator();
    error InvalidPubkeysLength();
    error InsufficientValidatorWithdrawalFee(uint256, uint256);
    error VaultOssified();
    error PubkeyLengthDoesNotMatchAmountLength();

    // From: contracts/0.8.25/vaults/ValidatorConsolidationRequests.sol
    error ConsolidationFeeReadFailed();
    error ConsolidationFeeInvalidData();
    error ConsolidationFeeRefundFailed(address, uint256);
    error ConsolidationRequestAdditionFailed(bytes);
    error NoConsolidationRequests();
    error MalformedPubkeysArray();
    error MalformedTargetPubkey();
    error MismatchingSourceAndTargetPubkeysCount(uint256, uint256);
    error InsufficientValidatorConsolidationFee(uint256, uint256);
    error VaultNotConnected();
    error NotDelegateCall();

    // From: contracts/0.8.25/vaults/VaultFactory.sol
    error InsufficientFunds();

    // // From: contracts/0.8.25/vaults/VaultHub.sol
    // error ZeroBalance();
    // error RebalanceAmountExceedsTotalValue(uint256, uint256);
    // error AmountExceedsWithdrawableValue(address, uint256, uint256);
    // error AlreadyHealthy(address);
    // error VaultMintingCapacityExceeded(address, uint256, uint256, uint256);
    // error InsufficientSharesToBurn(address, uint256);
    // error ShareLimitExceeded(address, uint256, uint256);
    // error AlreadyConnected(address, uint256);
    // error NotConnectedToHub(address);
    // // error ZeroArgument();
    // error InvalidBasisPoints(uint256, uint256);
    // error ShareLimitTooHigh(uint256, uint256);
    // error InsufficientValueToMint(address, uint256);
    // error NoLiabilitySharesShouldBeLeft(address, uint256);
    // error CodehashNotAllowed(address, bytes32);
    // error InvalidFees(address, uint256, uint256);
    // // error VaultOssified(address);
    // error VaultInsufficientBalance(address, uint256, uint256);
    // error VaultReportStale(address);
    // error PDGNotDepositor(address);
    // error ZeroCodehash();
    // error VaultHubNotPendingOwner(address);
    // error UnhealthyVaultCannotDeposit(address);
    // error VaultIsDisconnecting(address);
    // error VaultHasUnsettledObligations(address, uint256, uint256);
    // error PartialValidatorWithdrawalNotAllowed();
    // error ForcedValidatorExitNotAllowed();
    // error NoBadDebtToWriteOff(address, uint256, uint256);
    // error BadDebtSocializationNotAllowed();

    // // From: contracts/0.8.25/vaults/dashboard/Dashboard.sol
    // error ExceedsWithdrawable(uint256, uint256);
    // error ExceedsMintingCapacity(uint256, uint256);
    // error EthTransferFailed(address, uint256);
    // error ConnectedToVaultHub();
    // error TierChangeNotConfirmed();
    // error DashboardNotAllowed();

    // // From: contracts/0.8.25/vaults/dashboard/NodeOperatorFee.sol
    // error FeeValueExceed100Percent();
    // error IncreasedOverLimit();
    // error InvalidatedAdjustmentVote(uint256, uint256);
    // error SameAdjustment();
    // error SameRecipient();
    // error ReportStale();
    // error AdjustmentNotReported();
    // error AdjustmentNotSettled();
    // error VaultQuarantined();

    // // From: contracts/0.8.25/vaults/dashboard/Permissions.sol
    // error NonProxyCallsForbidden();
    // error AlreadyInitialized();

    // From: contracts/0.8.25/vaults/lib/PinnedBeaconUtils.sol
    error AlreadyOssified();

    // From: contracts/0.8.25/vaults/lib/RefSlotCache.sol
    error InOutDeltaCacheIsOverwritten();

    // From: contracts/0.8.25/vaults/predeposit_guarantee/CLProofVerifier.sol
    error InvalidTimestamp();
    error InvalidSlot();

    // From: contracts/0.8.25/vaults/predeposit_guarantee/PredepositGuarantee.sol
    error LockedIsNotZero(uint256);
    error ValueNotMultipleOfPredepositAmount(uint256);
    error NothingToRefund();
    error WithdrawalFailed();
    error SameGuarantor();
    error SameDepositor();
    error RefundFailed();
    error EmptyDeposits();
    error InvalidDepositYLength();
    error PredepositAmountInvalid(bytes, uint256);

    enum ValidatorStage {
        NONE,
        PREDEPOSITED,
        PROVEN,
        DISPROVEN,
        COMPENSATED
    }

    error ValidatorNotNew(bytes, ValidatorStage);
    error NotEnoughUnlocked(uint256, uint256);
    error WithdrawalCredentialsMismatch(address, address);
    error DepositToUnprovenValidator(bytes, ValidatorStage);
    error DepositToWrongVault(bytes, address);
    error ValidatorNotPreDeposited(bytes, ValidatorStage);
    error WithdrawalCredentialsMatch();
    error WithdrawalCredentialsMisformed(bytes32);
    error WithdrawalCredentialsInvalidVersion(uint8);
    error ValidatorNotDisproven(ValidatorStage);
    error CompensateFailed();
    error CompensateToVaultNotAllowed();
    error NotStakingVaultOwner();
    error NotGuarantor();
    error NotDepositor();

    // From: contracts/0.8.9/Accounting.sol
    error UnequalArrayLengths(uint256, uint256);
    error IncorrectReportTimestamp(uint256, uint256);
    error IncorrectReportValidators(uint256, uint256, uint256);

    // From: contracts/0.8.9/BeaconChainDepositor.sol
    error DepositContractZeroAddress();
    error InvalidPublicKeysBatchLength(uint256, uint256);
    error InvalidSignaturesBatchLength(uint256, uint256);

    // From: contracts/0.8.9/Burner.sol
    error AppAuthFailed();
    error MigrationNotAllowedOrAlreadyMigrated();
    error DirectETHTransfer();
    error ZeroRecoveryAmount();
    error StETHRecoveryWrongFunc();
    error ZeroBurnAmount();
    error BurnAmountExceedsActual(uint256, uint256);
    // error ZeroAddress(string);
    error OnlyLidoCanMigrate();
    error NotInitialized();

    // From: contracts/0.8.9/DepositSecurityModule.sol
    error DuplicateAddress(address);
    error NotAnOwner(address);
    error InvalidSignature();
    error SignaturesNotSorted();
    error DepositNoQuorum();
    error DepositRootChanged();
    error DepositInactiveModule();
    error DepositTooFrequent();
    error DepositUnexpectedBlockHash();
    error DepositsArePaused();
    error DepositsNotPaused();
    error ModuleNonceChanged();
    error PauseIntentExpired();
    error UnvetPayloadInvalid();
    error UnvetUnexpectedBlockHash();
    error NotAGuardian(address);
    error ZeroParameter(string);

    // From: contracts/0.8.9/EIP712StETH.sol
    error ZeroStETHAddress();

    // From: contracts/0.8.9/OracleDaemonConfig.sol
    error ValueExists(string);
    error EmptyValue(string);
    error ValueDoesntExist(string);
    error ValueIsSame(string, bytes);

    // From: contracts/0.8.9/StakingRouter.sol
    error ZeroAddressLido();
    error ZeroAddressAdmin();
    error ZeroAddressStakingModule();
    error InvalidStakeShareLimit();
    error InvalidFeeSum();
    error StakingModuleNotActive();
    error EmptyWithdrawalsCredentials();
    error InvalidReportData(uint256);
    error ExitedValidatorsCountCannotDecrease();
    error ReportedExitedValidatorsExceedDeposited(uint256, uint256);
    error StakingModulesLimitExceeded();
    error StakingModuleUnregistered();
    error AppAuthLidoFailed();
    error StakingModuleStatusTheSame();
    error StakingModuleWrongName();
    error UnexpectedCurrentValidatorsCount(uint256, uint256);
    error UnexpectedFinalExitedValidatorsCount(uint256, uint256);
    error InvalidDepositsValue(uint256, uint256);
    error StakingModuleAddressExists();
    error ArraysLengthMismatch(uint256, uint256);
    error UnrecoverableModuleError();
    error InvalidPriorityExitShareThreshold();
    error InvalidMinDepositBlockDistance();
    error InvalidMaxDepositPerBlockValue();

    // From: contracts/0.8.9/TriggerableWithdrawalsGateway.sol
    error InsufficientFee(uint256, uint256);
    error FeeRefundFailed();
    error ExitRequestsLimitExceeded(uint256, uint256);

    // From: contracts/0.8.9/WithdrawalQueue.sol
    error AdminZeroAddress();
    error RequestAmountTooSmall(uint256);
    error RequestAmountTooLarge(uint256);
    error InvalidReportTimestamp();
    error RequestIdsNotSorted();
    error ZeroRecipient();

    // From: contracts/0.8.9/WithdrawalQueueBase.sol
    error ZeroAmountOfETH();
    error ZeroShareRate();
    error ZeroTimestamp();
    error TooMuchEtherToFinalize(uint256, uint256);
    error NotOwner(address, address);
    error InvalidRequestId(uint256);
    error InvalidRequestIdRange(uint256, uint256);
    error InvalidState();
    error BatchesAreNotSorted();
    error EmptyBatches();
    error RequestNotFoundOrNotFinalized(uint256);
    error NotEnoughEther();
    error RequestAlreadyClaimed(uint256);
    error InvalidHint(uint256);
    error CantSendValueRecipientMayHaveReverted();

    // From: contracts/0.8.9/WithdrawalQueueERC721.sol
    error ApprovalToOwner();
    error ApproveToCaller();
    error NotOwnerOrApprovedForAll(address);
    error NotOwnerOrApproved(address);
    error TransferFromIncorrectOwner(address, address);
    error TransferToZeroAddress();
    error TransferFromZeroAddress();
    error TransferToThemselves();
    error TransferToNonIERC721Receiver(address);
    error InvalidOwnerAddress(address);
    error StringTooLong(string);
    error ZeroMetadata();

    // From: contracts/0.8.9/WithdrawalVault.sol
    error NotLido();
    error NotTriggerableWithdrawalsGateway();
    // error NotEnoughEther(uint256, uint256);
    error ZeroAmount();

    // From: contracts/0.8.9/WithdrawalVaultEIP7002.sol
    error FeeReadFailed();
    error FeeInvalidData();
    error IncorrectFee(uint256, uint256);
    error RequestAdditionFailed(bytes);

    // From: contracts/0.8.9/lib/ExitLimitUtils.sol
    error LimitExceeded();
    error TooLargeMaxExitRequestsLimit();
    error TooLargeFrameDuration();
    error TooLargeExitsPerFrame();
    error ZeroFrameDuration();

    // From: contracts/0.8.9/lib/PositiveTokenRebaseLimiter.sol
    error TooLowTokenRebaseLimit();
    error TooHighTokenRebaseLimit();
    error NegativeTotalPooledEther();

    // From: contracts/0.8.9/oracle/AccountingOracle.sol
    error LidoLocatorCannotBeZero();
    error LidoCannotBeZero();
    error IncorrectOracleMigration(uint256);
    error SenderNotAllowed();
    error InvalidExitedValidatorsData();
    error UnsupportedExtraDataFormat(uint256);
    error UnsupportedExtraDataType(uint256, uint256);
    error DeprecatedExtraDataType(uint256, uint256);
    error CannotSubmitExtraDataBeforeMainData();
    error ExtraDataAlreadyProcessed();
    error UnexpectedExtraDataHash(bytes32, bytes32);
    error UnexpectedExtraDataFormat(uint256, uint256);
    error ExtraDataItemsCountCannotBeZeroForNonEmptyData();
    error ExtraDataHashCannotBeZeroForNonEmptyData();
    error UnexpectedExtraDataItemsCount(uint256, uint256);
    error UnexpectedExtraDataIndex(uint256, uint256);
    error InvalidExtraDataItem(uint256);
    error InvalidExtraDataSortOrder(uint256);

    // From: contracts/0.8.9/oracle/BaseOracle.sol
    error AddressCannotBeZero();
    error AddressCannotBeSame();
    error VersionCannotBeSame();
    error UnexpectedChainConfig();
    error SenderIsNotTheConsensusContract();
    error InitialRefSlotCannotBeLessThanProcessingOne(uint256, uint256);
    error RefSlotMustBeGreaterThanProcessingOne(uint256, uint256);
    error RefSlotCannotDecrease(uint256, uint256);
    error NoConsensusReportToProcess();
    error ProcessingDeadlineMissed(uint256);
    error RefSlotAlreadyProcessing();
    error UnexpectedRefSlot(uint256, uint256);
    error UnexpectedConsensusVersion(uint256, uint256);
    error HashCannotBeZero();
    error UnexpectedDataHash(bytes32, bytes32);
    error SecondsPerSlotCannotBeZero();

    // From: contracts/0.8.9/oracle/HashConsensus.sol
    error InvalidChainConfig();
    error NumericOverflow();
    error ReportProcessorCannotBeZero();
    error DuplicateMember();
    error InitialEpochIsYetToArrive();
    error InitialEpochAlreadyArrived();
    error InitialEpochRefSlotCannotBeEarlierThanProcessingSlot();
    error EpochsPerFrameCannotBeZero();
    error NonMember();
    error QuorumTooSmall(uint256, uint256);
    error DuplicateReport();
    error EmptyReport();
    error StaleReport();
    error NonFastLaneMemberCannotReportWithinFastLaneInterval();
    error NewProcessorCannotBeTheSame();
    error ConsensusReportAlreadyProcessing();
    error FastLanePeriodCannotBeLongerThanFrame();

    // From: contracts/0.8.9/oracle/ValidatorsExitBus.sol
    error UnsupportedRequestsDataFormat(uint256);
    error InvalidRequestsDataLength();
    error InvalidModuleId();
    error InvalidRequestsDataSortOrder();
    error ExitHashNotSubmitted();
    error ExitHashAlreadySubmitted();
    error RequestsAlreadyDelivered();
    error ExitDataIndexOutOfRange(uint256, uint256);
    error InvalidExitDataIndexSortOrder();
    error RequestsNotDelivered();
    error TooManyExitRequestsInReport(uint256, uint256);

    // From: contracts/0.8.9/oracle/ValidatorsExitBusOracle.sol
    error UnexpectedRequestsDataLength();

    // From: contracts/0.8.9/proxy/OssifiableProxy.sol
    error NotAdmin();
    error ProxyIsOssified();

    // From: contracts/0.8.9/sanity_checks/OracleReportSanityChecker.sol
    error IncorrectLimitValue(uint256, uint256, uint256);
    error IncorrectWithdrawalsVaultBalance(uint256);
    error IncorrectELRewardsVaultBalance(uint256);
    error IncorrectSharesRequestedToBurn(uint256);
    error IncorrectCLBalanceIncrease(uint256);
    error IncorrectAppearedValidators(uint256);
    error IncorrectNumberOfExitRequestsPerReport(uint256);
    error IncorrectExitedValidators(uint256);
    error IncorrectRequestFinalization(uint256);
    error ActualShareRateIsZero();
    error TooManyItemsPerExtraDataTransaction(uint256, uint256);
    error ExitedValidatorsLimitExceeded(uint256, uint256);
    error TooManyNodeOpsPerExtraDataItem(uint256, uint256);
    error IncorrectCLBalanceDecrease(uint256, uint256);
    error NegativeRebaseFailedCLBalanceMismatch(uint256, uint256, uint256);
    error NegativeRebaseFailedWithdrawalVaultBalanceMismatch(uint256, uint256);
    error NegativeRebaseFailedSecondOpinionReportIsNotReady();
    error CalledNotFromAccounting();
    error BasisPointsOverflow(uint256, uint256);

    // From: contracts/0.8.9/utils/PausableUntil.sol
    error ZeroPauseDuration();
    error PausedExpected();
    error ResumedExpected();
    error PauseUntilMustBeInFuture();

    // From: contracts/0.8.9/utils/Versioned.sol
    error NonZeroContractVersionOnInit();
    error InvalidContractVersionIncrement();
    error UnexpectedContractVersion(uint256, uint256);

    // From: contracts/common/lib/BLS.sol
    error G2AddFailed();
    error PairingFailed();
    error MapFp2ToG2Failed();
    error InputHasInfinityPoints();
    error InvalidPubkeyLength();

    // From: contracts/common/lib/GIndex.sol
    error IndexOutOfRange();

    // From: contracts/common/lib/SSZ.sol
    error BranchHasMissingItem();
    error BranchHasExtraItem();

    // From: contracts/common/lib/TriggerableWithdrawals.sol
    error WithdrawalFeeReadFailed();
    error WithdrawalFeeInvalidData();
    error WithdrawalRequestAdditionFailed(bytes);
    error NoWithdrawalRequests();
    error PartialWithdrawalRequired(uint256);
    error MismatchedArrayLengths(uint256, uint256);

    // From: contracts/openzeppelin/5.2/upgradeable/access/OwnableUpgradeable.sol
    error OwnableUnauthorizedAccount(address);
    error OwnableInvalidOwner(address);

    // From: contracts/openzeppelin/5.2/upgradeable/proxy/utils/Initializable.sol
    error InvalidInitialization();
    error NotInitializing();

    // From: contracts/testnets/sepolia/SepoliaDepositAdapter.sol
    error EthRecoverFailed();
    error BepoliaRecoverFailed();
    error DepositFailed();

    // From: contracts/upgrade/V3Addresses.sol
    error NewAndOldLocatorImplementationsMustBeDifferent();
    error IncorrectStakingModuleName(string);

    // From: contracts/upgrade/V3Template.sol
    error OnlyAgentCanUpgrade();
    error UpgradeAlreadyStarted();
    error UpgradeAlreadyFinished();
    error IncorrectProxyAdmin(address);
    error IncorrectProxyImplementation(address, address);
    error InvalidContractVersion(address, uint256);
    error IncorrectOZAccessControlRoleHolders(address, bytes32);
    error NonZeroRoleHolders(address, bytes32);
    error IncorrectAragonAppImplementation(address, address);
    error StartAndFinishMustBeInSameBlock();
    error StartAndFinishMustBeInSameTx();
    error StartAlreadyCalledInThisTx();
    error Expired();
    error IncorrectBurnerSharesMigration(string);
    error IncorrectBurnerAllowance(address, address);
    error BurnerMigrationNotAllowed();
    error IncorrectVaultFactoryBeacon(address, address);
    error IncorrectVaultFactoryDashboardImplementation(address, address);
    error IncorrectUpgradeableBeaconOwner(address, address);
    error IncorrectUpgradeableBeaconImplementation(address, address);
    error TotalSharesOrPooledEtherChanged();
}