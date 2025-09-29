// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";

error InsufficientShares(uint256 required, uint256 available);

/**
 * @title WrapperA
 * @notice Configuration A: No minting, no strategy - Simple stvETH shares without stETH minting
 */
contract WrapperA is WrapperBase {
    constructor(address _dashboard, bool _allowListEnabled, address _withdrawalQueue)
        WrapperBase(_dashboard, _allowListEnabled, _withdrawalQueue)
    {}

    function wrapperType() public pure override returns (string memory) {
        return "WrapperA";
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Simple deposit with stvETH shares only
     * @param _receiver Address to receive the minted shares
     * @param _referral Address to credit for referral (optional)
     * @return stvShares Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral) public payable override returns (uint256 stvShares) {
        stvShares = _deposit(_receiver, _referral);
    }

    /**
     * @notice Request withdrawal for Configuration A (no minting, no strategy)
     * @param _stvShares Amount of stvETH shares to withdraw
     * @return requestId The withdrawal request ID
     */
    function requestWithdrawal(uint256 _stvShares) external returns (uint256 requestId) {
        if (_stvShares == 0) revert WrapperBase.ZeroStvShares();

        _transfer(msg.sender, address(WITHDRAWAL_QUEUE), _stvShares);

        requestId = WITHDRAWAL_QUEUE.requestWithdrawal(_stvShares, msg.sender);
    }
}
