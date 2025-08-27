// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IStETH} from "./interfaces/IStETH.sol";

/**
 * @title WrapperB
 * @notice Configuration B: Minting, no strategy - stvETH shares + maximum stETH minting for user
 */
contract WrapperB is WrapperBase {

    error InsufficientSharesLocked(address user);

    IStETH public immutable STETH;

    constructor(
        address _dashboard,
        address _stETH,
        bool _allowListEnabled
    ) WrapperBase(_dashboard, _allowListEnabled) {
        STETH = IStETH(_stETH);
    }

    function initialize(
        address _owner,
        string memory _name,
        string memory _symbol
    ) public override initializer {
        WrapperBase.initialize(_owner, _name, _symbol);

        DASHBOARD.grantRole(DASHBOARD.MINT_ROLE(), address(this));
        DASHBOARD.grantRole(DASHBOARD.BURN_ROLE(), address(this));
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Deposits and mints maximum stETH to user
     * @param _receiver Address to receive the minted shares
     * @return stvShares Number of stvETH shares minted
     */
    function depositETH(address _receiver) public payable override returns (uint256 stvShares) {
        if (msg.value == 0) revert WrapperBase.ZeroDeposit();
        if (_receiver == address(0)) revert WrapperBase.InvalidReceiver();
        _checkAllowList();

        DASHBOARD.fund{value: msg.value}();

        stvShares = previewDeposit(msg.value);
        _mint(_receiver, stvShares);

        _mintMaximumStETH(_receiver, stvShares);

        emit Deposit(msg.sender, _receiver, msg.value, stvShares);
    }

    /**
     * @notice Calculate the amount of stETH shares required for a given amount of stvETH shares to withdraw
     * @param _stvETHShares The amount of stvETH shares to withdraw
     * @return stETHShares The corresponding amount of stETH shares needed for withdrawal
     */
    function stethForWithdrawal(uint256 _stvETHShares) public view returns (uint256 stETHShares) {
        stETHShares = _getCorrespondingShare(_stvETHShares, DASHBOARD.liabilityShares());
    }

    /**
     * @notice Request withdrawal for Configuration B (minting, no strategy)
     * @param _stvETHShares Amount of stvETH shares to withdraw
     * @param _stETHShares Amount of stETH shares to burn - must be approved for
     * @return requestId The withdrawal request ID
     */
    function requestWithdrawal(uint256 _stvETHShares, uint256 _stETHShares) external returns (uint256 requestId) {
        if (_stvETHShares == 0) revert WrapperBase.ZeroStvShares();

        // TODO: maybe calc stETH shares by stethForWithdrawal(_stvETHShares)
        WithdrawalQueue withdrawalQueue = withdrawalQueue();

        _transfer(msg.sender, address(withdrawalQueue), _stvETHShares);

        STETH.transferSharesFrom(msg.sender, address(DASHBOARD), _stETHShares);
        DASHBOARD.burnShares(_stETHShares);

        requestId = withdrawalQueue.requestWithdrawal(msg.sender, _convertToAssets(_stvETHShares));
    }

    /**
     * @notice Claim finalized withdrawal request
     * @param _requestId The withdrawal request ID to claim
     */
    function claimWithdrawal(uint256 _requestId) external override {
        WithdrawalQueue withdrawalQueue = withdrawalQueue();
        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(_requestId);

        _burn(address(withdrawalQueue), status.amountOfShares);
        withdrawalQueue.claimWithdrawal(_requestId);
    }

}