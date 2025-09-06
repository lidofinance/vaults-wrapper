// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import {IStETH} from "./IStETH.sol";


interface ILido is IStETH {

    function submit(address _referral) external payable returns (uint256);

    function resume() external;

    function isStopped() external view returns (bool);

    function setMaxExternalRatioBP(uint256 _maxExternalRatioBP) external;

    function STAKING_CONTROL_ROLE() external view returns (bytes32);


    function mintShares(address _recipient, uint256 _amountOfShares) external;
    function burnShares(uint256 _amountOfShares) external;

}
