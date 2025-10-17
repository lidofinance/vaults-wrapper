// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperB} from "./WrapperB.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/**
 * @title WrapperC
 * @notice Configuration C: Minting functionality with strategy - stvETH shares with stETH minting capability and strategy integration
 */
contract WrapperC is WrapperB {
    IStrategy public immutable STRATEGY;

    event StrategyExecuted(address indexed user, uint256 stv, uint256 targetStethShares);

    error InvalidSender();

    constructor(
        address _dashboard,
        bool _allowListEnabled,
        address _strategy,
        uint256 _reserveRatioGapBP,
        address _withdrawalQueue
    ) WrapperB(_dashboard, _allowListEnabled, _reserveRatioGapBP, _withdrawalQueue) {
        STRATEGY = IStrategy(_strategy);
    }

    function wrapperType() external pure virtual override returns (string memory) {
        return "WrapperC";
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Funds the vault and mints shares to the receiver, then executes strategy
     * @param _receiver Address to receive the minted shares
     * @param _referral Address to credit for referral (optional)
     * @return stv Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral) public payable virtual override returns (uint256 stv) {
        uint256 targetStethShares = calcStethSharesToMintForAssets(msg.value);
        stv = depositETH(_receiver, _referral, targetStethShares, bytes(""));
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares, optionally minting stETH shares
     * @param _receiver Address to receive the minted shares
     * @param _referral Address to credit for referral (optional)
     * @param _stethSharesToMint Amount of stETH shares to mint (up to maximum capacity for this deposit)
     *                           Pass MAX_MINTABLE_AMOUNT to mint maximum available for this deposit
     * @return stv Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral, uint256 _stethSharesToMint) public payable virtual override returns (uint256 stv) {
        stv = depositETH(_receiver, _referral, _stethSharesToMint, bytes(""));
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares, optionally minting stETH shares
     * @param _receiver Address to receive the minted shares
     * @param _referral Address to credit for referral (optional)
     * @param _stethSharesToMint Amount of stETH shares to mint (up to maximum capacity for this deposit)
     *                           Pass MAX_MINTABLE_AMOUNT to mint maximum available for this deposit
     * @param _params The parameters for the deposit
     * @return stv Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral, uint256 _stethSharesToMint, bytes memory _params) public payable virtual returns (uint256 stv) {
        stv = _deposit(address(STRATEGY), _referral);
        STRATEGY.execute(_receiver, stv, _stethSharesToMint, _params);
    }

    function requestWithdrawalFromStrategy(uint256 _stethAmount, bytes calldata params) public returns (bytes32 requestId) {
        requestId = STRATEGY.requestExitByStETH(msg.sender, _stethAmount, params);
    }

    function finalizeWithdrawalFromStrategy(address _receiver, bytes32 _requestId) external {
        STRATEGY.finalizeExit(msg.sender, _receiver, _requestId);
    }
}
