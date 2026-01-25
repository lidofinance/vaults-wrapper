// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IShareManager is IERC20 {
    function vault() external view returns (address);

    function sharesOf(address account) external view returns (uint256 shares);

    function claimableSharesOf(address account) external view returns (uint256 shares);

    function activeSharesOf(address account) external view returns (uint256 shares);
}
