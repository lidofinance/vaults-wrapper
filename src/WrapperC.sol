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

    IStrategy public STRATEGY;

    error NotStrategy();

    constructor(
        address _dashboard,
        address _stETH,
        bool _allowListEnabled,
        address _strategy
    ) WrapperB(_dashboard, _stETH, _allowListEnabled) {
        // Strategy can be set to zero initially and set later via setStrategy
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
        uint256 strategyMintableStSharesBefore = this.mintableStShares(address(STRATEGY));
        uint256 mintableStSharesBefore = DASHBOARD.remainingMintingCapacityShares(0);
        stvShares = _deposit(address(STRATEGY), _referral);
        uint256 strategyMintableStSharesAfter = this.mintableStShares(address(STRATEGY));
        uint256 mintableStSharesAfter = DASHBOARD.remainingMintingCapacityShares(0);

        uint256 newStrategyMintableStShares = strategyMintableStSharesAfter - strategyMintableStSharesBefore;

        // uint256 newMintableStShares = mintableStSharesAfter - mintableStSharesBefore;
        // require(newStrategyMintableStShares == newMintableStShares, "Strategy mintable stETH shares do not match mintable stETH shares");

        // TODO: add assert
        // assert(mintableStShares(address(STRATEGY), stvShares) == mintableStSharesAfter - mintableStSharesBefore);
        STRATEGY.execute(_receiver, stvShares, newStrategyMintableStShares);
    }

    function depositForStrategy() external payable returns (uint256 stvShares) {
        if (msg.sender != address(STRATEGY)) revert NotStrategy();
        stvShares = _deposit(address(STRATEGY), address(0));
    }

    /**
     * @notice Requests a withdrawal of the specified amount of stvETH shares via the strategy.
     *         Requires having position in the strategy with enough stvETH shares.
     * @dev Forwards the withdrawal request to the configured strategy contract.
     * @param _stvShares The amount of stvETH shares to withdraw.
     */
    function requestWithdrawalFromStrategy(uint256 _stvShares) external {
        STRATEGY.requestWithdraw(msg.sender,_stvShares);
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

    // TODO: get rid of this and make STRATEGY immutable
    function setStrategy(address _strategy) external {
        _checkRole(DEFAULT_ADMIN_ROLE);
        if (_strategy == address(0)) {
            revert InvalidConfiguration();
        }
        STRATEGY = IStrategy(_strategy);
    }
}
