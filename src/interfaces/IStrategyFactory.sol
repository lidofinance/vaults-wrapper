// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

/// @title IStrategyFactory
/// @notice Interface for strategy factory contracts like GGVStrategyFactory
interface IStrategyFactory {
    /// @notice Deploys a new strategy contract instance
    /// @param _pool Address of the pool contract
    /// @param _steth Address of the stETH token
    /// @param _wsteth Address of the wstETH token
    /// @param _teller Address of the teller contract
    /// @param _boringQueue Address of the boring queue contract
    /// @return impl The address of the newly deployed strategy contract
    function deploy(address _pool, address _steth, address _wsteth, address _teller, address _boringQueue)
        external
        returns (address impl);
}
