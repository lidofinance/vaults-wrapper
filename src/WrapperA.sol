// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

error InsufficientShares(uint256 required, uint256 available);

/**
 * @title WrapperA
 * @notice Configuration A: No minting, no strategy - Simple stvETH shares without stETH minting
 */
contract WrapperA is WrapperBase {

    constructor(
        address _dashboard,
        bool _allowListEnabled
    ) WrapperBase(_dashboard, _allowListEnabled) {}

    function initialize(
        address _owner,
        string memory _name,
        string memory _symbol
    ) public override initializer {
        WrapperBase.initialize(_owner, _name, _symbol);
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Simple deposit with stvETH shares only
     * @param _receiver Address to receive the minted shares
     * @return stvShares Number of stvETH shares minted
     */
    function depositETH(address _receiver) public payable override returns (uint256 stvShares) {
        if (msg.value == 0) revert WrapperBase.ZeroDeposit();
        if (_receiver == address(0)) revert WrapperBase.InvalidReceiver();
        _checkAllowList();

        stvShares = previewDeposit(msg.value);
        _mint(_receiver, stvShares);
        DASHBOARD.fund{value: msg.value}();

        emit Deposit(msg.sender, _receiver, msg.value, stvShares);
    }

    /**
     * @notice Request withdrawal for Configuration A (no minting, no strategy)
     * @param _stvETHShares Amount of stvETH shares to withdraw
     * @return requestId The withdrawal request ID
     */
    function requestWithdrawal(uint256 _stvETHShares) external returns (uint256 requestId) {
        if (_stvETHShares == 0) revert WrapperBase.ZeroStvShares();

        _burn(msg.sender, _stvETHShares); // balance is checked in _burn

        // TODO: maybe redo WQ to accept shares
        uint256 assets = _convertToAssets(_stvETHShares);
        requestId = withdrawalQueue().requestWithdrawal(msg.sender, assets);
    }
}
