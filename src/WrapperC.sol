// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";
import {WrapperA} from "./WrapperA.sol";
import {WrapperB} from "./WrapperB.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

error InvalidConfiguration();

/**
 * @title WrapperC
 * @notice Configuration C: Minting functionality with strategy - stvETH shares with stETH minting capability and strategy integration
 */
contract WrapperC is WrapperB {

    IStrategy public immutable STRATEGY;

    constructor(
        address _dashboard,
        address _stETH,
        bool _allowListEnabled,
        address _strategy
    ) WrapperB(_dashboard, _stETH, _allowListEnabled) {
        if (_strategy == address(0)) {
            revert InvalidConfiguration();
        }
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

        // Then execute strategy with the minted shares
        STRATEGY.execute(_receiver, stvShares);
    }
}
