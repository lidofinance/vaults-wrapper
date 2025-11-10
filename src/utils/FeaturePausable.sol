// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

/**
 * @title FeaturePausable
 * @notice Generic feature pausable helper that allows inheriting contracts to gate arbitrary flows
 * @dev Stores paused states per feature id and exposes internal checks plus pause/unpause helpers
 */
abstract contract FeaturePausable {
    // =================================================================================
    // STORAGE
    // =================================================================================

    /// @custom:storage-location erc7201:pool.storage.FeaturePausable
    struct FeaturePausableStorage {
        mapping(bytes32 featureId => bool isPaused) _isFeaturePaused;
    }

    // keccak256(abi.encode(uint256(keccak256("pool.storage.FeaturePausable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FEATURE_PAUSABLE_STORAGE_LOCATION =
        0x15990678dc6e70d79055b1ed64b76145ce68c29f966eaa9eea39165e8a41bd00;

    function _getFeaturePausableStorage() private pure returns (FeaturePausableStorage storage $) {
        assembly {
            $.slot := FEATURE_PAUSABLE_STORAGE_LOCATION
        }
    }

    // =================================================================================
    // EVENTS
    // =================================================================================

    event FeaturePaused(bytes32 indexed featureId, address indexed account);
    event FeatureUnpaused(bytes32 indexed featureId, address indexed account);

    // =================================================================================
    // ERRORS
    // =================================================================================

    error FeaturePauseEnforced(bytes32 featureId);
    error FeaturePauseExpected(bytes32 featureId);

    // =================================================================================
    // PUBLIC METHODS
    // =================================================================================

    /**
     * @notice Check if a feature is paused
     * @param featureId Feature identifier
     * @return isPaused True if paused
     */
    function isFeaturePaused(bytes32 featureId) public view returns (bool isPaused) {
        isPaused = _getFeaturePausableStorage()._isFeaturePaused[featureId];
    }

    // =================================================================================
    // CHECK HELPERS
    // =================================================================================

    /**
     * @notice Revert if a feature is paused
     * @param featureId Feature identifier
     */
    function _checkFeatureNotPaused(bytes32 featureId) internal view {
        if (isFeaturePaused(featureId)) revert FeaturePauseEnforced(featureId);
    }

    /**
     * @notice Revert if a feature is not paused
     * @param featureId Feature identifier
     */
    function _checkFeaturePaused(bytes32 featureId) internal view {
        if (!isFeaturePaused(featureId)) revert FeaturePauseExpected(featureId);
    }

    // =================================================================================
    // PAUSE/UNPAUSE HELPERS
    // =================================================================================

    /**
     * @notice Pause a feature
     * @param featureId Feature identifier
     */
    function _pauseFeature(bytes32 featureId) internal {
        _checkFeatureNotPaused(featureId);
        _getFeaturePausableStorage()._isFeaturePaused[featureId] = true;
        emit FeaturePaused(featureId, msg.sender);
    }

    /**
     * @notice Resume a feature
     * @param featureId Feature identifier
     */
    function _resumeFeature(bytes32 featureId) internal {
        _checkFeaturePaused(featureId);
        _getFeaturePausableStorage()._isFeaturePaused[featureId] = false;
        emit FeatureUnpaused(featureId, msg.sender);
    }
}
