// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

contract Distributor is AccessControlEnumerable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant MANAGER_ROLE = keccak256("distributor.MANAGER_ROLE");
    
    /// @notice Merkle root of the distribution
    bytes32 public root;

    /// @notice IPFS CID of the last published Merkle tree
    string public cid;

    /// @notice Mapping of claimed amounts by account and token
    mapping(address account => mapping(address token => uint256 amount)) public claimed;

    /// @notice Mapping of claimable amounts by token
    mapping(address token => uint256 amount) public claimable;

    /// @notice List of supported tokens
    EnumerableSet.AddressSet private tokens;

    /// @notice Last processed block number for user tracking
    uint256 public lastProcessedBlock;

    constructor(address _owner) {
        lastProcessedBlock = block.number;

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(MANAGER_ROLE, _owner);
    }

    /// @notice Add a token to the list of supported tokens
    /// @param token The address of the token to add
    function addToken(address token) external onlyRole(MANAGER_ROLE) {
        tokens.add(token);

        emit TokenAdded(token);
    }

    /// @notice Get the list of supported tokens
    /// @return tokens The list of supported tokens
    function getTokens() external view returns (address[] memory) {
        return tokens.values();
    }

    function setMerkleRoot(bytes32 _root, string calldata _cid) external onlyRole(MANAGER_ROLE) {
        if (_root == root || keccak256(bytes(_cid)) == keccak256(bytes(cid))) revert AlreadyProcessed();

        emit MerkleRootUpdated(root, _root, cid, _cid, lastProcessedBlock, block.number);

        root = _root;
        cid = _cid;
        lastProcessedBlock = block.number;
    }

    /// @notice Claims rewards.
    /// @param _recipient The address to claim rewards for.
    /// @param _token The address of the reward token.
    /// @param _amount The overall claimable amount of token rewards.
    /// @param _proof The merkle proof that validates this claim.
    /// @return amount The amount of reward token claimed.
    /// @dev Anyone can claim rewards on behalf of an account.
    function claim(address _recipient, address _token, uint256 _amount, bytes32[] calldata _proof)
        external
        returns (uint256 amount)
    {
        if (root == bytes32(0)) revert RootNotSet();
        if (!MerkleProof.verifyCalldata(
                _proof, root, keccak256(bytes.concat(keccak256(abi.encode(_recipient, _token, _amount))))
            )
        ) revert InvalidProof();

        if (_amount <= claimed[_recipient][_token]) revert ClaimableTooLow();

        amount = _amount - claimed[_recipient][_token];

        claimed[_recipient][_token] = _amount;

        IERC20(_token).safeTransfer(_recipient, amount);

        emit Claimed(_recipient, _token, amount);
    }

    event TokenAdded(address indexed token);
    event Claimed(address indexed recipient, address indexed token, uint256 amount);
    event MerkleRootUpdated(
        bytes32 oldRoot, bytes32 newRoot, 
        string oldCid, string newCid, 
        uint256 oldBlock, uint256 newBlock);

    error AlreadyProcessed();
    error InvalidProof();
    error ClaimableTooLow();
    error RootNotSet();
}
