// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {WrapperB} from "./WrapperB.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {WithdrawalRequest} from "./strategy/WithdrawalRequest.sol";


/**
 * @title WrapperC
 * @notice Configuration C: Minting functionality with strategy - stvETH shares with stETH minting capability and strategy integration
 */
contract WrapperC is WrapperB {
    using EnumerableSet for EnumerableSet.UintSet;

    IStrategy public immutable STRATEGY;

    /// @custom:storage-location erc7201:wrapper.strategy.storage
    struct WrapperStrategyStorage {
        WithdrawalRequest[] withdrawalRequests;
        mapping(address => EnumerableSet.UintSet) requestsByOwner;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.strategy.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_STRATEGY_STORAGE_LOCATION =
        0x76c92ae68eaa959f76afc10fd368073d675fe474488a86150a8ad065d1775b00;

    event StrategyExecuted(address indexed user, uint256 stvShares, uint256 targetStethShares);
    event StrategyWithdrawalRequested(uint256 requestId, bytes32 strategyRequestId, address indexed user, uint256 amount, uint40 timestamp);
    event StrategyWithdrawalFinalized(uint256 requestId, bytes32 strategyRequestId, address indexed user, uint256 amount, uint40 timestamp);

    error InvalidSender();

    constructor(
        address _dashboard,
        bool _allowListEnabled,
        address _strategy,
        uint256 _reserveRatioGapBP,
        address _withdrawalQueue
    ) WrapperB(_dashboard, _allowListEnabled, _reserveRatioGapBP, _withdrawalQueue) {
        STRATEGY = IStrategy(_strategy);
    }

    function wrapperType() external pure virtual override returns (string memory) {
        return "WrapperC";
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Funds the vault and mints shares to the receiver, then executes strategy
     * @param _receiver Address to receive the minted shares
     * @param _referral Address to credit for referral (optional)
     * @return stvShares Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral) public payable override returns (uint256 stvShares) {
        uint256 targetStethShares = _calcStethSharesToMintForAssets(msg.value);
        stvShares = _deposit(address(STRATEGY), _referral);
        STRATEGY.execute(_receiver, stvShares, targetStethShares);

        emit StrategyExecuted(_receiver, stvShares, targetStethShares);
    }

    function requestWithdrawalFromStrategy(uint256 _stethAmount, bytes calldata params) public returns (uint256 requestId) {
        bytes32 strategyRequestId = STRATEGY.requestWithdrawByStETH(msg.sender, _stethAmount, params);

        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        requestId = $.withdrawalRequests.length;
        WithdrawalRequest memory request = WithdrawalRequest({
            strategyRequestId: strategyRequestId,
            owner: msg.sender,
            timestamp: uint40(block.timestamp),
            stethAmount: _stethAmount
        });

        $.withdrawalRequests.push(request);
        $.requestsByOwner[msg.sender].add(requestId);

        emit StrategyWithdrawalRequested(requestId, strategyRequestId, msg.sender, _stethAmount, uint40(block.timestamp));
    }

    function finalizeWithdrawalFromStrategy(uint256 _requestId) external {
        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        WithdrawalRequest memory request = $.withdrawalRequests[_requestId];

        $.requestsByOwner[request.owner].remove(_requestId);

        STRATEGY.finalizeWithdrawal(request);

        emit StrategyWithdrawalFinalized(_requestId, request.strategyRequestId, request.owner, request.stethAmount, request.timestamp);
    }

    /// @notice Requests a withdrawal of the specified amount of stvETH shares from the strategy
    /// @param _owner The address that owns the stvETH shares
    /// @param _receiver The address to receive the stETH
    /// @param _stvShares The amount of stvETH shares to withdraw
    /// @return requestId The ID of the created withdrawal request
    function requestWithdrawalQueue(address _owner, address _receiver, uint256 _stvShares)
        external
        returns (uint256 requestId)
    {
        if (msg.sender != address(STRATEGY)) revert InvalidSender();
        requestId = _requestWithdrawalQueue(_owner, _receiver, _stvShares, 0);
    }

    // =================================================================================
    // WITHDRAWALS
    // =================================================================================

    /// @notice Returns all withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @return requestIds array of request ids
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestIds) {
        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        return $.requestsByOwner[_owner].values();
    }

    /// @notice Returns all withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @param _start start index
    /// @param _end end index
    /// @return requestIds array of request ids
    function getWithdrawalRequests(
        address _owner,
        uint256 _start,
        uint256 _end
    ) external view returns (uint256[] memory requestIds) {
        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        return $.requestsByOwner[_owner].values(_start, _end);
    }

    /// @notice Returns the length of the withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @return length of the withdrawal requests
    function getWithdrawalRequestsLength(address _owner) external view returns (uint256 length) {
        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        return $.requestsByOwner[_owner].length();
    }

    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return _getWrapperStrategyStorage().withdrawalRequests[requestId];
    }

    function _getWrapperStrategyStorage() internal pure returns (WrapperStrategyStorage storage $) {
        assembly {
            $.slot := WRAPPER_STRATEGY_STORAGE_LOCATION
        }
    }
}
