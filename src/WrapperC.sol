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

    error NotStrategy();

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

    /**
     * @notice Requests a withdrawal of the specified amount of stvETH shares without involving the strategy.
     *         Requires having the stvShares and enough stETH approved for this contract
     * @dev Calls the parent contract's requestWithdrawal function directly.
     * @param _stvShares The amount of stvETH shares to withdraw.
     * @return requestId The ID of the created withdrawal request.
     */
    function requestWithdrawal(uint256 _stvShares) public override returns (uint256 requestId) {
        return super.requestWithdrawal(_stvShares);
    }

}
