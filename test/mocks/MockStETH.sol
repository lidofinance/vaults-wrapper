// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockStETH is ERC20 {
    uint256 private totalShares;
    mapping(address => uint256) private shares;
    
    constructor() ERC20("Mock stETH", "stETH") {}
    
    function getSharesByPooledEth(uint256 ethAmount) external pure returns (uint256) {
        return ethAmount; // 1:1 for simplicity
    }
    
    function getPooledEthByShares(uint256 sharesAmount) external pure returns (uint256) {
        return sharesAmount; // 1:1 for simplicity
    }
    
    function transferSharesFrom(address from, address to, uint256 amount) external returns (bool) {
        shares[from] -= amount;
        shares[to] += amount;
        return true;
    }
    
    function sharesOf(address account) external view returns (uint256) {
        return shares[account];
    }
}