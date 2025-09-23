// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockBoringVault} from "./MockBoringVault.sol";

contract MockTeller {

    MockBoringVault public immutable vault;

    constructor(address _vault) {
        vault = MockBoringVault(payable(_vault));
    }

    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint) external returns (uint256 shares) {
        address from = msg.sender;
        address to = msg.sender;

        shares = vault.previewEnter(depositAsset, depositAmount);
        require(shares >= minimumMint, "Insufficient shares minted");

        vault.enter(from, depositAsset, depositAmount, to, shares);
    }
}