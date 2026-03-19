// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IShareManager is IERC20 {
    function vault() external view returns (address);

    function isDepositorWhitelisted(address account, bytes32[] calldata merkleProof) external view returns (bool);

    function sharesOf(address account) external view returns (uint256 shares);

    function claimableSharesOf(address account) external view returns (uint256 shares);

    function activeSharesOf(address account) external view returns (uint256 shares);
}
