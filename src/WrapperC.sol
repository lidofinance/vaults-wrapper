// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {WrapperB} from "./WrapperB.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {console} from "forge-std/Test.sol";

error InvalidConfiguration();

/**
 * @title WrapperC
 * @notice Configuration C: Minting functionality with strategy - stvETH shares with stETH minting capability and strategy integration
 */
contract WrapperC is WrapperB {
    using EnumerableSet for EnumerableSet.UintSet;

    IStrategy public STRATEGY;

    error InvalidSender();

    constructor(
        address _dashboard,
        address _stETH,
        bool _allowListEnabled,
        address _strategy,
        uint256 _reserveRatioGapBP
    ) WrapperB(_dashboard, _stETH, _allowListEnabled, _reserveRatioGapBP) {
        STRATEGY = IStrategy(_strategy);
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Funds the vault and mints shares to the receiver, then executes strategy
     * @param _receiver Address to receive the minted shares
     * @param _referral Address to credit for referral (optional)
     * @return stvShares Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral) public payable override returns (uint256 stvShares) {
        stvShares = _deposit(address(STRATEGY), _referral);
        STRATEGY.execute(_receiver, stvShares);
    }

    function depositForStrategy() external payable returns (uint256 stvShares) {
        if (msg.sender != address(STRATEGY)) revert InvalidSender();
        stvShares = _deposit(address(STRATEGY), address(0));
    }

    function requestWithdrawalFromStrategy(uint256 _ethAmount) public returns (uint256 requestId) {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        requestId = $.withdrawalRequests.length;
        WithdrawalRequest memory request = WithdrawalRequest({
            requestId: requestId,
            requestType: WithdrawalType.STRATEGY,
            owner: msg.sender,
            timestamp: uint40(block.timestamp),
            amount: _ethAmount
        });

        $.withdrawalRequests.push(request);
        $.requestsByOwner[msg.sender].add(requestId);

        STRATEGY.requestWithdrawByETH(msg.sender, _ethAmount);

        emit WithdrawalRequestCreated(request.requestId, msg.sender, request.requestType);
    }

    function finalizeWithdrawal(uint256 _requestId) external {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        WithdrawalRequest memory request = $.withdrawalRequests[_requestId];

        if (request.requestType != WithdrawalType.STRATEGY) revert InvalidRequestType();

        $.requestsByOwner[request.owner].remove(_requestId);

        STRATEGY.finalizeWithdrawal(request.owner, request.amount);
    }

    function getWithdrawableAmount(address _address) external view returns (uint256 ethAmount) {
        return STRATEGY.getWithdrawableAmount(_address);
    }


    /// @notice Requests a withdrawal of the specified amount of stvETH shares from the strategy
    /// @param _owner The address that owns the stvETH shares
    /// @param _receiver The address to receive the stETH
    /// @param _stvShares The amount of stvETH shares to withdraw
    /// @return requestId The ID of the created withdrawal request
    function requestWithdrawalQueue(address _owner, address _receiver, uint256 _stvShares) external returns (uint256 requestId) {
        if (msg.sender != address(STRATEGY)) revert InvalidSender();
        requestId = _requestWithdrawalQueue(_owner, _receiver,_stvShares);
    }

    /// @notice Adds a withdrawal request by strategy
    function addWithdrawalRequest(WithdrawalRequest memory _request) external returns (uint256 requestId) {
        if (msg.sender != address(STRATEGY)) revert InvalidSender();
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        requestId = $.withdrawalRequests.length;
        $.withdrawalRequests.push(_request);
        $.requestsByOwner[_request.owner].add(requestId);
    }

    function getRequest(uint256 requestId) external returns (WithdrawalRequest memory) {
        return _getWrapperBaseStorage().withdrawalRequests[requestId];
    }

    // TODO: get rid of this and make STRATEGY immutable
    function setStrategy(address _strategy) external {
        _checkRole(DEFAULT_ADMIN_ROLE);
        if (_strategy == address(0)) {
            revert InvalidConfiguration();
        }
        STRATEGY = IStrategy(_strategy);
    }
}
