// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperB} from "./WrapperB.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/**
 * @title WrapperC
 * @notice Configuration C: Minting functionality with strategy - stv with stETH minting capability and strategy integration
 */
contract WrapperC is WrapperB {
    IStrategy public immutable STRATEGY;

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
}
