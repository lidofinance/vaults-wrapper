// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LenderMock {
    address public immutable STETH;
    uint256 public constant TOTAL_BASIS_POINTS = 10000;
    uint256 public constant BORROW_RATIO = 7500; // 0.75 in basis points

    constructor(address _steth) {
        STETH = _steth;
    }

    /// @notice Borrow ETH against stETH collateral
    /// @param _amount Amount of stETH to transfer in
    function borrow(uint256 _amount) external {
        uint256 ethAmount = (_amount * BORROW_RATIO) / TOTAL_BASIS_POINTS;
        require(address(this).balance >= ethAmount, "Insufficient ETH in contract");

        require(IERC20(STETH).transferFrom(msg.sender, address(this), _amount), "stETH transfer failed");

        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "ETH transfer failed");
    }

    receive() external payable {}
}