// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

contract LoopStrategyFactory {
    function deploy(address _steth, address _wrapper, uint256 _loops) external returns (address impl) {
        //        impl = address(new LoopStrategy(_steth, _wrapper, _loops));
    }
}
