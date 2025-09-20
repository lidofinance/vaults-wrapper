// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {console} from "forge-std/console.sol";

contract MockBoringVault is ERC20, Ownable{

    uint256 public shareRate = 1e18;

    mapping (address user => mapping (address asset => uint256 balance)) public deposits;

    uint256 public _totalSupply;

    //============================== EVENTS ===============================

    event Enter(address indexed from, address indexed asset, uint256 amount, address indexed to, uint256 shares);
    event Exit(address indexed to, address indexed asset, uint256 amount, address indexed from, uint256 shares);
    event ShareRateUpdated(uint256 oldRate, uint256 newRate);

    constructor() ERC20("Mock GGV Vault", "MGGV") Ownable(msg.sender) {}

    function setShareRate(uint256 _rate) external onlyOwner {
        uint256 oldRate = shareRate;
        shareRate = _rate;
        emit ShareRateUpdated(oldRate, _rate);
    }

    function enter(address from, ERC20 asset, uint256 assetAmount, address to, uint256 shareAmount)
        external
    {
        // Transfer assets in
        if (assetAmount > 0) asset.transferFrom(from, address(this), assetAmount);

        // Mint shares.
        _mint(to, shareAmount);

        emit Enter(from, address(asset), assetAmount, to, shareAmount);
    }

    function exit(address to, ERC20 asset, uint256 assetAmount, address from, uint256 shareAmount)
        external
    {
        // Burn shares.
        _burn(from, shareAmount);

        // Transfer assets out.
        if (assetAmount > 0) asset.transfer(to, assetAmount);

        emit Exit(to, address(asset), assetAmount, from, shareAmount);
    }

    function previewEnter(ERC20 depositAsset, uint256 depositAmount) external returns(uint256) {
        uint256 supply = depositAsset.totalSupply();

        if (supply == 0 || totalSupply() == 0) {
            return depositAmount * 797237821400583551/799999999999999999; //
        }

        return Math.mulDiv(depositAmount, supply, totalSupply(), Math.Rounding.Floor);
    }

    receive() external payable {}
}