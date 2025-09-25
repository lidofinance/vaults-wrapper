// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStETH} from "src/interfaces/IStETH.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";

interface IWrapper {
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function getStethShares(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

library TableUtils {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));


    struct Context {
        IWrapper wrapper;
        IERC20 boringVault;
        IStETH steth;
        IBoringOnChainQueue boringQueue;
        uint16 discount;
    }

    struct User {
        address user;
        string name;
    }

    function init(
        Context storage self,
        address _wrapper,
        address _boringVault,
        address _steth,
        address _boringQueue,
        uint16 _discount
    ) internal {
        self.wrapper = IWrapper(_wrapper);
        self.boringVault = IERC20(_boringVault);
        self.steth = IStETH(_steth);
        self.boringQueue = IBoringOnChainQueue(_boringQueue);
        self.discount = _discount;
    }

    function printHeader(Context storage self, string memory title) internal {
        console.log();
        console.log();
        console.log(title);
        console.log(unicode"───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────");
        printColumnHeaders(self);
    }

    function printColumnHeaders(Context storage self) internal {
        console.log(
            string.concat(
                padRight("user", 16),
                padLeft("balance", 14),
                padLeft("stv", 14),
                padLeft("eth", 14),
                padLeft("debt_steth", 20),
                padLeft("ggv", 20),
                padLeft("ggvStethOut", 20),
                padLeft("stETH", 20)
            )
        );
        console.log(unicode"───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────");
    }

    function printUsers(Context storage self, string memory title, User[] memory _addresses) internal {
        printHeader(self, title);

        for (uint256 i = 0; i < _addresses.length; i++) {
            printUserRow(self, _addresses[i].name, _addresses[i].user);
        }

        uint256 stethShareRate = self.steth.getPooledEthByShares(1e18);

        console.log(unicode"───────────────────────────────────");
        console.log("  stETH Share Rate:", formatETH(stethShareRate));
        console.log("wrapper totalSupply", formatETH(self.wrapper.totalSupply()));
        console.log("wrapper totalAssets", formatETH(self.wrapper.totalAssets()));
    }

    function printUserRow(
        Context storage self,
        string memory userName,
        address _user
    ) internal {

        uint256 balance = _user.balance;
        uint256 stv = self.wrapper.balanceOf(_user);
        uint256 assets = self.wrapper.previewRedeem(stv);
        uint256 debtSteth = self.wrapper.getStethShares(_user);
        uint256 ggv = self.boringVault.balanceOf(_user);
        uint256 ggvStethOut = self.boringQueue.previewAssetsOut(address(self.steth), uint128(ggv), self.discount);
        uint256 steth = self.steth.balanceOf(_user);

        console.log(
            string.concat(
                padRight(userName, 16),
                padLeft(formatETH(balance), 14),
                padLeft(formatETH(stv), 14),
                padLeft(formatETH(assets), 14),
                padLeft(vm.toString(debtSteth), 20),
                padLeft(vm.toString(ggv), 20),
                padLeft(vm.toString(ggvStethOut), 20),
                padLeft(vm.toString(steth), 20)
            )
        );
    }

    function formatETH(uint256 weiAmount) internal pure returns (string memory) {
        return formatWithDecimals(weiAmount, 18);
    }

    function formatWithDecimals(uint256 amount, uint256 decimals) internal pure returns (string memory) {
        if (amount == 0) return "0.00";
        
        uint256 divisor = 10 ** decimals;
        uint256 integerPart = amount / divisor;
        uint256 fractionalPart = amount % divisor;
        
        // Для 2 знаков после запятой берем первые 2 цифры дробной части
        uint256 scaledFractional = fractionalPart / (divisor / 100);
        
        return string.concat(
            vm.toString(integerPart),
            ".",
            padWithZeros(vm.toString(scaledFractional), 2)
        );
    }

    function padWithZeros(string memory str, uint256 length) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length >= length) return str;
        
        bytes memory result = new bytes(length);
        uint256 i;
        
        // Заполняем нулями слева
        for (i = 0; i < length - strBytes.length; i++) {
            result[i] = '0';
        }
        
        // Добавляем исходную строку
        for (uint256 j = 0; j < strBytes.length; j++) {
            result[i + j] = strBytes[j];
        }
        
        return string(result);
    }

    function padRight(string memory str, uint256 length) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length >= length) return str;
        
        bytes memory result = new bytes(length);
        uint256 i;
        for (i = 0; i < strBytes.length; i++) {
            result[i] = strBytes[i];
        }
        for (; i < length; i++) {
            result[i] = ' ';
        }
        return string(result);
    }

    function padLeft(string memory str, uint256 length) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length >= length) return str;
        
        bytes memory result = new bytes(length);
        uint256 padding = length - strBytes.length;
        uint256 i;
        for (i = 0; i < padding; i++) {
            result[i] = ' ';
        }
        for (uint256 j = 0; j < strBytes.length; j++) {
            result[i + j] = strBytes[j];
        }
        return string(result);
    }
}