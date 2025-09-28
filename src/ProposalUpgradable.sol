// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";

/**
 * @title ProposalUpgradable
 * @notice Base contract providing two-step delayed upgrade functionality for wrappers and their associated withdrawal queues
 * @dev exposes virtual functions to be overridden by inheriting contracts
 */
abstract contract ProposalUpgradable is Initializable, AccessControlEnumerableUpgradeable {
    // Upgrade events
    event WrapperUpgradeProposed(address _newImplementation, address _newWqImplementation, bytes32 proposalHash);
    event WrapperUpgradeCancelled(bytes32 proposalHash);
    event WrapperUpgradeConfirmed(bytes32 proposalHash, uint64 enactTimestamp);
    event WrapperUpgradeEnacted(address _newImplementation, address _newWqImplementation, bytes32 proposalHash);

    // Custom errors
    error NoMatchingProposal();
    error UpgradeNotAllowed();
    error AlreadyProposed();
    error AlreadyConfirmed();
    error NotYetConfirmed();
    error TooEarlyToEnact();

    // upgrade roles
    bytes32 public constant UPGRADE_CONFORMER = keccak256("UPGRADE_CONFORMER");
    bytes32 public constant UPGRADE_PROPOSER = keccak256("UPGRADE_PROPOSER");

    struct WrapperUpgradePayload {
        address newImplementation;
        address newWqImplementation;
        bytes upgradeData;
    }

    // Upgrade consts
    uint64 public immutable UPGRADE_DELAY = 7 days;

    /// @custom:storage-location erc7201:wrapper.upgrade.storage
    struct ProposalUpgradableStorage {
        bytes32 proposalHash;
        uint64 confirmationTimestamp;
    }

    // TODO: verify this constant
    // keccak256(abi.encode(uint256(keccak256("wrapper.upgrade.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PROPOSAL_UPGRADABLE_STORAGE_LOCATION =
        0xb7c4e3fdabcc2bda791137ff0285a25f08943f4abbae909e94df75d1cf8e7900;

    function _getProposalUpgradableStorage() private pure returns (ProposalUpgradableStorage storage $) {
        assembly {
            $.slot := PROPOSAL_UPGRADABLE_STORAGE_LOCATION
        }
    }

    function _initializeProposalUpgradable(address _proposer, address _conformer) internal onlyInitializing {
        _grantRole(UPGRADE_PROPOSER, _proposer);
        _setRoleAdmin(UPGRADE_CONFORMER, UPGRADE_CONFORMER);
        if (_conformer != address(0)) {
            _grantRole(UPGRADE_CONFORMER, _conformer);
        }
    }

    // =================================================================================
    // View functions
    // =================================================================================

    function getCurrentUpgradeProposal() external pure returns (ProposalUpgradableStorage memory) {
        return _getProposalUpgradableStorage();
    }

    // =================================================================================
    // Upgrade functions
    // =================================================================================

    function proposeUpgrade(WrapperUpgradePayload calldata _payload) external returns (bytes32) {
        _checkRole(UPGRADE_PROPOSER, msg.sender);

        bytes32 proposalHash = _hashUpgradePayload(_payload);
        ProposalUpgradableStorage storage $ = _getProposalUpgradableStorage();

        if ($.proposalHash == proposalHash) {
            revert AlreadyProposed();
        }

        $.proposalHash = proposalHash;
        $.confirmationTimestamp = 0;

        emit WrapperUpgradeProposed(_payload.newImplementation, _payload.newWqImplementation, proposalHash);

        return proposalHash;
    }

    function cancelUpgradeProposal() external {
        _checkRole(UPGRADE_PROPOSER, msg.sender);

        ProposalUpgradableStorage storage $ = _getProposalUpgradableStorage();

        if ($.proposalHash == bytes32(0)) {
            revert NoMatchingProposal();
        }

        if ($.confirmationTimestamp != 0) {
            revert AlreadyConfirmed();
        }

        emit WrapperUpgradeCancelled($.proposalHash);
        $.proposalHash = bytes32(0);
    }

    function confirmUpgrade(WrapperUpgradePayload calldata _payload) external {
        _checkRole(UPGRADE_CONFORMER, msg.sender);
        // check if upgrade is allowed before starting countdown via confirm
        _beforeUpgrade();

        bytes32 proposalHash = _hashUpgradePayload(_payload);

        ProposalUpgradableStorage storage $ = _getProposalUpgradableStorage();

        if ($.proposalHash != proposalHash) {
            revert NoMatchingProposal();
        }

        if ($.confirmationTimestamp != 0) {
            revert AlreadyConfirmed();
        }

        $.confirmationTimestamp = uint64(block.timestamp);

        emit WrapperUpgradeConfirmed($.proposalHash, $.confirmationTimestamp + UPGRADE_DELAY);
    }

    function enactUpgrade(WrapperUpgradePayload calldata _payload) external {
        _beforeUpgrade();
        // anyone can call this, no need to check roles

        ProposalUpgradableStorage storage $ = _getProposalUpgradableStorage();

        bytes32 proposalHash = _hashUpgradePayload(_payload);

        if ($.proposalHash != proposalHash) {
            revert NoMatchingProposal();
        }

        if ($.confirmationTimestamp == 0) {
            revert NotYetConfirmed();
        }

        if (block.timestamp < $.confirmationTimestamp + UPGRADE_DELAY) {
            revert TooEarlyToEnact();
        }

        // Reset proposal
        $.proposalHash = bytes32(0);
        $.confirmationTimestamp = 0;

        // First upgrade the withdrawal queue
        withdrawalQueue().upgradeTo(_payload.newWqImplementation);
        // Then upgrade the wrapper itself
        ERC1967Utils.upgradeToAndCall(_payload.newImplementation, _payload.upgradeData);

        emit WrapperUpgradeEnacted(_payload.newImplementation, _payload.newWqImplementation, proposalHash);
    }

    // =================================================================================
    // Virtual Functions
    // =================================================================================

    function withdrawalQueue() public view virtual returns (WithdrawalQueue);

    // Override this function to add custom upgrade checks
    function _canUpgrade() internal view virtual returns (bool) {
        return true;
    }

    // =================================================================================
    // Internal functions
    // =================================================================================

    function _beforeUpgrade() internal view {
        if (!_canUpgrade()) {
            revert UpgradeNotAllowed();
        }
    }

    function _hashUpgradePayload(WrapperUpgradePayload calldata _payload) internal pure returns (bytes32) {
        return keccak256(abi.encode(_payload));
    }
}
