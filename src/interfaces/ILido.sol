// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

// See contracts/COMPILERS.md
// solhint-disable-next-line lido/fixed-compiler-version
pragma solidity >=0.8.0;

import {IStETH} from "./IStETH.sol";


interface ILido is IStETH {

    function submit(address _referral) external payable returns (uint256);

    function resume() external;

    function isStopped() external view returns (bool);

    function setMaxExternalRatioBP(uint256 _maxExternalRatioBP) external;

    function STAKING_CONTROL_ROLE() external view returns (bytes32);

}
