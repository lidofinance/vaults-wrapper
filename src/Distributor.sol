// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Distributor {
    using SafeERC20 for IERC20;

    /// @notice Merkle root of the distribution
    bytes32 public root;

    /// @notice IPFS CID of the last published Merkle tree
    string public cid;

    /// @notice Mapping of claimed amounts by account and token
    mapping(address account => mapping(address token => uint256 amount)) public claimed;

    /// @notice Mapping of claimable amounts by token
    mapping(address token => uint256 amount) public claimable;

    /// @notice List of supported tokens
    address[] public supportedTokens;

    /// @notice Last processed block number for user tracking
    uint256 public lastProcessedBlock;

    constructor() {
        lastProcessedBlock = block.number;
    }

    function addSupportedToken(address token) external {
        supportedTokens.push(token);
    }

    /// @notice Get the amount of tokens that are pending to be distributed
    /// @param token The token to check
    /// @return amount The amount of tokens that are pending to distribute
    function tokenToDistribute(address token) external view returns (uint256 amount) {
        return IERC20(token).balanceOf(address(this)) - claimable[token];
    }

    function processDistribution(address _token, bytes32 _root, string calldata _cid, uint256 _distributed) external {
        if (_root == root || keccak256(bytes(_cid)) == keccak256(bytes(cid))) revert AlreadyProcessed();

        root = _root;
        cid = _cid;
        claimable[_token] += _distributed;

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

    event Claimed(address indexed recipient, address indexed token, uint256 amount);

    error AlreadyProcessed();
    error InvalidProof();
    error ClaimableTooLow();
    error RootNotSet();
}
