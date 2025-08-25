// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";

error InsufficientShares(uint256 required, uint256 available);

/**
 * @title WrapperA
 * @notice Configuration A: No minting, no strategy - Simple stvETH shares without stETH minting
 */
contract WrapperA is WrapperBase {

    constructor(
        address _dashboard,
        address _owner,
        string memory _name,
        string memory _symbol,
        bool _allowListEnabled
    ) WrapperBase(_dashboard, _owner, _name, _symbol, _allowListEnabled) {}

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Simple deposit with stvETH shares only
     * @param _receiver Address to receive the minted shares
     * @return shares Number of stvETH shares minted
     */
    function depositETH(address _receiver) public payable override returns (uint256 shares) {
        if (msg.value == 0) revert WrapperBase.ZeroDeposit();
        if (_receiver == address(0)) revert WrapperBase.InvalidReceiver();

        // Check allowlist if enabled
        _checkAllowList();

        uint256 totalAssetsBefore = totalAssets();
        uint256 totalSupplyBefore = totalSupply();

        // Calculate shares before funding
        shares = previewDeposit(msg.value);

        // Fund vault through Dashboard
        DASHBOARD.fund{value: msg.value}();

        // Mint stvETH shares to receiver
        _mint(_receiver, shares);

        emit Deposit(msg.sender, _receiver, msg.value, shares);

        assert(totalAssets() == totalAssetsBefore + msg.value);
        assert(totalSupply() == totalSupplyBefore + shares);

        return shares;
    }

    /**
     * @notice Request withdrawal for Configuration A (no minting, no strategy)
     * @param _stvETHShares Amount of stvETH shares to withdraw
     * @return requestId The withdrawal request ID
     */
    function requestWithdrawal(uint256 _stvETHShares) external returns (uint256 requestId) {
        if (_stvETHShares == 0) revert WrapperBase.ZeroStvShares();
        if (balanceOf(msg.sender) < _stvETHShares) {
            revert InsufficientShares(_stvETHShares, balanceOf(msg.sender));
        }

        requestId = withdrawalQueue().requestWithdrawal(msg.sender, _convertToAssets(_stvETHShares));
        _burn(msg.sender, _stvETHShares);

        emit Withdraw(msg.sender, _convertToAssets(_stvETHShares), _stvETHShares);
    }

    /**
     * @notice Claim finalized withdrawal request
     * @param _requestId The withdrawal request ID to claim
     */
    function claimWithdrawal(uint256 _requestId) external {
        withdrawalQueue().claimWithdrawal(_requestId);
    }
}