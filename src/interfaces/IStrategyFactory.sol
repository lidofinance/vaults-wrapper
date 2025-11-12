// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

/// @title IStrategyFactory
/// @notice Interface for strategy factory contracts like GGVStrategyFactory
interface IStrategyFactory {
    /// @notice Deploys a new strategy contract instance
    /// @param _pool Address of the pool contract
    /// @return impl The address of the newly deployed strategy contract
    function deploy(address _pool) external returns (address impl);
}
