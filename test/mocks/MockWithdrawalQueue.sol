// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStvStETHPool} from "../../src/interfaces/IStvStETHPool.sol";
import {IStETH} from "../../src/interfaces/core/IStETH.sol";

contract MockWithdrawalQueue {
    IStvStETHPool public POOL;

    function _getPooledEthBySharesRoundUp(uint256 _stethShares) internal view returns (uint256 ethAmount) {
        ethAmount = IStETH(POOL.STETH()).getPooledEthBySharesRoundUp(_stethShares);
    }

    function setPool(address pool) external {
        POOL = IStvStETHPool(pool);
    }

    function requestWithdrawal(address _owner, uint256 _stvToWithdraw, uint256 _stethSharesToRebalance)
        external
        returns (uint256 requestId)
    {
        requestId = _requestWithdrawal(_owner, _stvToWithdraw, _stethSharesToRebalance);
    }

    function _requestWithdrawal(address _owner, uint256 _stvToWithdraw, uint256 _stethSharesToRebalance)
        internal
        returns (uint256 requestId)
    {
        if (_owner == address(0)) revert("error 1");
        if (_stethSharesToRebalance > 0) revert("error 2");
        _transferForWithdrawalQueue(msg.sender, _stvToWithdraw, _stethSharesToRebalance);
        requestId = 0;
    }

    function _transferForWithdrawalQueue(address _from, uint256 _stv, uint256 _stethShares) internal {
        if (_stethShares == 0) {
            POOL.transferFromForWithdrawalQueue(_from, _stv);
        } else {
            POOL.transferFromWithLiabilityForWithdrawalQueue(_from, _stv, _stethShares);
        }
    }
}
