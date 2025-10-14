// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract WithdrawalQueueFactory {
    function deploy(
        address _wrapper,
        address _dashboard,
        address _vaultHub,
        address _steth,
        address _vault,
        address _lazyOracle,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime
    )
        external
        returns (address impl)
    {
        impl = address(new WithdrawalQueue(
            _wrapper,
            _dashboard,
            _vaultHub,
            _steth,
            _vault,
            _lazyOracle,
            _maxFinalizationTime,
            _minWithdrawalDelayTime
        ));
    }
}
