// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IShareManager {
    /// @return address Returns address of the vault using this ShareManager
    function vault() external view returns (address);

    /// @return shares Returns total shares (active + claimable) for an account
    function sharesOf(address account) external view returns (uint256 shares);

    /// @return shares Returns claimable shares for an account
    function claimableSharesOf(address account) external view returns (uint256 shares);

    /// @return shares Returns active shares for an account
    function activeSharesOf(address account) external view returns (uint256 shares);
}
