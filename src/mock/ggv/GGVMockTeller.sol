// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {GGVVaultMock} from "./GGVVaultMock.sol";
import {BorrowedMath} from "./BorrowedMath.sol";
import {IStETH} from "src/interfaces/IStETH.sol";

contract GGVMockTeller is ITellerWithMultiAssetSupport {
    struct Asset {
        bool allowDeposits;
        bool allowWithdraws;
        uint16 sharePremium;
    }

    address public immutable owner;
    GGVVaultMock public immutable _vault;
    uint256 internal immutable ONE_SHARE;
    IStETH public immutable steth;

    mapping(ERC20 asset => Asset) public assets;

    constructor(address _owner, address __vault, address _steth, address _wsteth) {
        owner = _owner;
        _vault = GGVVaultMock(__vault);
        steth = IStETH(_steth);

        // eq to 10 ** vault.decimals()
        ONE_SHARE = 10 ** 18;

        _updateAssetData(ERC20(_steth), true, true, 0);
        _updateAssetData(ERC20(_wsteth), true, true, 0);
    }

    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint)
        external
        returns (uint256 shares)
    {
        Asset memory asset = assets[depositAsset];
        if (!asset.allowDeposits) {
            revert("Deposits not allowed");
        }
        if (depositAmount == 0) {
            revert("Deposit amount must be greater than 0");
        }
        if (depositAsset != ERC20(address(steth))) {
            revert("Asset not supported");
        }

        // hardcode share calculation for only steth
        shares = _vault.getSharesByAssets(steth.getSharesByPooledEth(depositAmount));
        // apply premium if any
        shares = asset.sharePremium > 0 ? BorrowedMath.mulDivDown(shares, 1e4 - asset.sharePremium, 1e4) : shares;

        if (shares < minimumMint) {
            revert("Minted shares less than minimumMint");
        }

        _vault.depositByTeller(address(depositAsset), shares, depositAmount, msg.sender);
    }

    function _updateAssetData(ERC20 asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium) internal {
        assets[asset] = Asset(allowDeposits, allowWithdraws, sharePremium);
    }

    function updateAssetData(ERC20 asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium) external {
        require(msg.sender == owner, "Only owner can update asset data");
        _updateAssetData(asset, allowDeposits, allowWithdraws, sharePremium);
    }

    function authority() external view returns (address) {
        return owner;
    }

    function vault() external view returns (address) {
        return address(_vault);
    }

    // STUBS

    function accountant() external view returns (address) {
        return address(this);
    }

    event NonPure();

    function bulkDeposit(ERC20, uint256, uint256, address) external returns (uint256) {
        emit NonPure();
        revert("not implemented");
    }

    function bulkWithdraw(ERC20, uint256, uint256, address) external returns (uint256) {
        emit NonPure();
        revert("not implemented");
    }
}
