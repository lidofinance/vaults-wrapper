// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {WrapperB} from "./WrapperB.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

error InvalidConfiguration();

/**
 * @title WrapperC
 * @notice Configuration C: Minting functionality with strategy - stvETH shares with stETH minting capability and strategy integration
 */
contract WrapperC is WrapperB {
    using EnumerableSet for EnumerableSet.UintSet;

    IStrategy public immutable STRATEGY;

    error InvalidSender();

    constructor(
        address _dashboard,
        address _stETH,
        bool _allowListEnabled,
        address _strategy,
        uint256 _reserveRatioGapBP,
        address _withdrawalQueue
    ) WrapperB(_dashboard, _stETH, _allowListEnabled, _reserveRatioGapBP, _withdrawalQueue) {
        STRATEGY = IStrategy(_strategy);
    }

    function wrapperType() external pure override virtual returns (string memory) {
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
        uint256 targetStethShares = _calcTargetStethSharesAmount(msg.value);
        stvShares = _deposit(address(STRATEGY), _referral);
        STRATEGY.execute(_receiver, stvShares, targetStethShares);
    }

    function requestWithdrawalFromStrategy(uint256 _stethAmount) public returns (uint256 requestId) {
        requestId = _addWithdrawalRequest(msg.sender, _stethAmount, WithdrawalType.STRATEGY);
        STRATEGY.requestWithdrawByETH(msg.sender, _stethAmount);
    }

    function finalizeWithdrawal(uint256 _requestId) external {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        WithdrawalRequest memory request = $.withdrawalRequests[_requestId];

        if (request.requestType != WithdrawalType.STRATEGY) revert InvalidRequestType();

        $.requestsByOwner[request.owner].remove(_requestId);

        STRATEGY.finalizeWithdrawal(request.owner, request.amount);
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

    function getRequest(uint256 requestId) external returns (WithdrawalRequest memory) {
        return _getWrapperBaseStorage().withdrawalRequests[requestId];
    }

}
