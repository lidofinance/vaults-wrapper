// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {GGVVaultMock} from "./GGVVaultMock.sol";
import {IStETH} from "src/interfaces/IStETH.sol";
import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";

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

    event ReferralAddress(address indexed referralAddress);

    constructor(address _owner, address __vault, address _steth, address _wsteth) {
        owner = _owner;
        _vault = GGVVaultMock(__vault);
        steth = IStETH(_steth);

        // eq to 10 ** vault.decimals()
        ONE_SHARE = 10 ** 18;

        _updateAssetData(ERC20(_steth), true, false, 0);
        _updateAssetData(ERC20(_wsteth), false, true, 0);
    }

    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint, address referralAddress)
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

        uint256 stethShares = steth.getSharesByPooledEth(depositAmount);

        // hardcode share calculation for only steth
        shares = _vault.getSharesByAssets(stethShares);
        if (shares < minimumMint) revert("Minted shares less than minimumMint");

        _vault.depositByTeller(address(depositAsset), shares, stethShares, msg.sender);

        emit ReferralAddress(referralAddress);
    }

    function _updateAssetData(ERC20 asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium) internal {
        assets[asset] =
            Asset({allowDeposits: allowDeposits, allowWithdraws: allowWithdraws, sharePremium: sharePremium});
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
