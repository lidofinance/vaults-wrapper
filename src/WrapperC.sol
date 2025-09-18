// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";
import {WrapperB} from "./WrapperB.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

error InvalidConfiguration();

/**
 * @title WrapperC
 * @notice Configuration C: Minting functionality with strategy - stvETH shares with stETH minting capability and strategy integration
 */
contract WrapperC is WrapperB {
    using EnumerableSet for EnumerableSet.UintSet;

    IStrategy public STRATEGY;

    error NotStrategy();

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
        uint256 mintableStSharesBefore = DASHBOARD.remainingMintingCapacityShares(0);
        stvShares = _deposit(address(STRATEGY), _referral);

        uint256 newStrategyMintableStShares = DASHBOARD.remainingMintingCapacityShares(0) - mintableStSharesBefore;

        // TODO: add assert?
        // assert(mintableStethShares(address(STRATEGY), stvShares) == mintableStSharesAfter - mintableStSharesBefore);
        STRATEGY.execute(_receiver, stvShares, newStrategyMintableStShares);
    }

    function depositForStrategy() external payable returns (uint256 stvShares) {
        if (msg.sender != address(STRATEGY)) revert NotStrategy();
        stvShares = _deposit(address(STRATEGY), address(0));
    }

    /**
     * @notice Requests a withdrawal of the specified amount of stvETH shares without involving the strategy.
     *         Requires having the stvShares and enough stETH approved for this contract
     * @dev Calls the parent contract's requestWithdrawal function directly.
     * @param _stvShares The amount of stvETH shares to withdraw.
     * @return requestId The ID of the created withdrawal request.
     */
    function requestWithdrawal(uint256 _stvShares) public override returns (WithdrawalRequest memory) {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        uint256 requestId = $.withdrawalRequests.length;
        WithdrawalRequest memory request = WithdrawalRequest({
            requestId: requestId,
            requestType: WithdrawalType.STRATEGY,
            owner: msg.sender
        });
        $.withdrawalRequests.push(request);

        $.requestsByOwner[msg.sender].add(requestId);
        $.requestsByOwner[address(STRATEGY)].add(requestId);

        STRATEGY.requestWithdraw(msg.sender, _stvShares);

        emit WithdrawalRequestCreated(request.requestId, msg.sender, request.requestType);

        return request;
    }

    function finalizeWithdrawal(uint256 _requestId, uint256 _stvShares) external {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        WithdrawalRequest memory request = $.withdrawalRequests[_requestId];
        if (request.requestType != WithdrawalType.STRATEGY) revert WrapperBase.InvalidRequestType();

        $.requestsByOwner[request.owner].remove(_requestId);
        $.requestsByOwner[address(STRATEGY)].remove(_requestId);

        STRATEGY.finalizeWithdrawal(request.owner, _stvShares);
    }


    /// @notice Requests a withdrawal of the specified amount of stvETH shares from the strategy
    /// @param _owner The address that owns the stvETH shares
    /// @param _receiver The address to receive the stETH
    /// @param _stvShares The amount of stvETH shares to withdraw
    /// @return requestId The ID of the created withdrawal request
    function requestWithdrawalQueue(address _owner, address _receiver, uint256 _stvShares) external returns (uint256 requestId) {
        if (msg.sender != address(STRATEGY)) revert NotStrategy();
        requestId = _requestWithdrawalQueue(_owner, _receiver,_stvShares);
    }

    /// @notice Adds a withdrawal request by strategy
    function addWithdrawalRequest(WithdrawalRequest memory _request) external {
        if (msg.sender != address(STRATEGY)) revert NotStrategy();
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        $.withdrawalRequests.push(_request);
        $.requestsByOwner[_request.owner].add(_request.requestId);
    }

    function getRequestStatus(uint256 requestId) external returns (WithdrawalRequest memory) {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        return $.withdrawalRequests[requestId];
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
