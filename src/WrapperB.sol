// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IStETH} from "./interfaces/IStETH.sol";

/**
 * @title WrapperB
 * @notice Configuration B: Minting, no strategy - stvETH shares + maximum stETH minting for user
 */
contract WrapperB is WrapperBase {
    using EnumerableSet for EnumerableSet.UintSet;

    event StethSharesMinted(address indexed account, uint256 stethShares);
    event StethSharesBurned(address indexed account, uint256 stethShares);
    event StethSharesRebalanced(uint256 stethShares, uint256 stvBurned);
    event SocializedLoss(uint256 stv, uint256 assets);

    error InsufficientMintingCapacity();
    error InsufficientStethShares();
    error InsufficientBalance();
    error InsufficientReservedBalance();
    error InsufficientMintedShares();
    error InsufficientStv();
    error ZeroArgument();
    error MintingForThanTargetStSharesShareIsNotAllowed();
    error TodoError();

    uint256 public immutable WRAPPER_RR_BP; // vault's reserve ratio plus gap for wrapper

    /// @custom:storage-location erc7201:wrapper.b.storage
    struct WrapperBStorage {
        mapping(address => uint256) mintedStethShares;
        uint256 totalMintedStethShares;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.b.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_B_STORAGE_LOCATION =
        0x68280b7606a1a98bf19dd7ad4cb88029b355c2c81a554f53b998c73f934e4400;

    function _getWrapperBStorage() internal pure returns (WrapperBStorage storage $) {
        assembly {
            $.slot := WRAPPER_B_STORAGE_LOCATION
        }
    }

    constructor(
        address _dashboard,
        bool _allowListEnabled,
        uint256 _reserveRatioGapBP,
        address _withdrawalQueue
    ) WrapperBase(_dashboard, _allowListEnabled, _withdrawalQueue) {
        uint256 vaultRR = DASHBOARD.reserveRatioBP();
        require(_reserveRatioGapBP < TOTAL_BASIS_POINTS - vaultRR, "Reserve ratio gap too high");
        WRAPPER_RR_BP = vaultRR + _reserveRatioGapBP;
    }

    function initialize(
        address _owner,
        address _upgradeConformer,
        string memory _name,
        string memory _symbol
    ) public override initializer {
        _initializeWrapperBase(_owner, _upgradeConformer, _name, _symbol);

        // Approve max stETH to the Dashboard for burning
        STETH.approve(address(DASHBOARD), type(uint256).max);
    }

    function wrapperType() external pure virtual override returns (string memory) {
        return "WrapperB";
    }

    // =================================================================================
    // DEPOSIT
    // =================================================================================

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @param _receiver Address to receive the minted shares
     * @param _referral Address of the referral (if any)
     * @return stv Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral) public payable virtual override returns (uint256 stv) {
        stv = depositETH(_receiver, _referral, 0);
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares, optionally minting stETH shares
     * @param _receiver Address to receive the minted shares
     * @param _referral Address of the referral (if any)
     * @param _stethSharesToMint Amount of stETH shares to mint (up to maximum capacity)
     * @return stv Amount of stvETH shares minted
     */
    function depositETH(
        address _receiver,
        address _referral,
        uint256 _stethSharesToMint
    ) public payable returns (uint256 stv) {
        stv = _deposit(_receiver, _referral);

        if (_stethSharesToMint > 0) {
            _mintStethShares(_receiver, _stethSharesToMint);
        }
    }

    // =================================================================================
    // WITHDRAWALS
    // =================================================================================

    /**
     * @notice Calculate the amount of ETH that can be withdrawn by an account
     * @param _account The address of the account
     * @return ethAmount The amount of ETH that can be withdrawn (18 decimals)
     */
    function withdrawableEth(address _account) public view returns (uint256 ethAmount) {
        ethAmount = withdrawableEth(_account, 0);
    }

    /**
     * @notice Calculate the amount of ETH that can be withdrawn by burning a specific amount of stETH shares
     * @param _account The address of the account
     * @param _stethSharesToBurn The amount of stETH shares to burn
     * @return ethAmount The amount of ETH that can be withdrawn (18 decimals)
     */
    function withdrawableEth(address _account, uint256 _stethSharesToBurn) public view returns (uint256 ethAmount) {
        uint256 mintedStethShares = mintedStethSharesOf(_account);
        if (mintedStethShares < _stethSharesToBurn) revert InsufficientStethShares();

        uint256 mintedStethSharesAfter = mintedStethShares - _stethSharesToBurn;
        uint256 minLockedAssetsAfter = _calcAssetsToLockForStethShares(mintedStethSharesAfter);
        uint256 currentAssets = effectiveAssetsOf(_account);
        ethAmount = Math.saturatingSub(currentAssets, minLockedAssetsAfter);
    }

    /**
     * @notice Calculate the amount of stvETH shares that can be withdrawn by an account
     * @param _account The address of the account
     * @return stv The amount of stvETH shares that can be withdrawn (18 decimals)
     */
    function withdrawableStv(address _account) public view returns (uint256 stv) {
        stv = withdrawableStv(_account, 0);
    }

    /**
     * @notice Calculate the amount of stvETH shares that can be withdrawn by an account
     * @param _account The address of the account
     * @param _stethSharesToBurn The amount of stETH shares to burn
     * @return stv The amount of stvETH shares that can be withdrawn (18 decimals)
     */
    function withdrawableStv(address _account, uint256 _stethSharesToBurn) public view returns (uint256 stv) {
        stv = _convertToShares(withdrawableEth(_account, _stethSharesToBurn), Math.Rounding.Floor);
    }

    /**
     * @notice Calculate the amount of stETH shares required for a given amount of stvETH shares to withdraw
     * @param _stv The amount of stvETH shares to withdraw
     * @return stethShares The corresponding amount of stETH shares needed to burn (18 decimals)
     */
    function stethSharesForWithdrawal(address _account, uint256 _stv) public view returns (uint256 stethShares) {
        if (_stv == 0) return 0;

        uint256 currentBalance = balanceOf(_account);
        if (currentBalance < _stv) revert InsufficientBalance();

        uint256 balanceAfter = currentBalance - _stv;
        uint256 maxStethSharesAfter = _calcStethSharesToMintForStv(balanceAfter);
        stethShares = Math.saturatingSub(mintedStethSharesOf(_account), maxStethSharesAfter);
    }

    /**
     * @notice Request a withdrawal by specifying the amount of assets to withdraw
     * @param _assetsToWithdraw The amount of assets to withdraw (18 decimals)
     * @return requestId The ID of the withdrawal request
     */
    function requestWithdrawalETH(uint256 _assetsToWithdraw) public virtual returns (uint256 requestId) {
        uint256 stvToWithdraw = _convertToShares(_assetsToWithdraw, Math.Rounding.Ceil);
        requestId = _requestWithdrawalQueue(msg.sender, msg.sender, stvToWithdraw, 0, 0);
    }

    /**
     * @notice Request a withdrawal by specifying the amount of stv to withdraw
     * @param _stvToWithdraw The amount of stv to withdraw (27 decimals)
     * @return requestId The ID of the withdrawal request
     */
    function requestWithdrawal(uint256 _stvToWithdraw) public virtual returns (uint256 requestId) {
        requestId = _requestWithdrawalQueue(msg.sender, msg.sender, _stvToWithdraw, 0, 0);
    }

    /**
     * @notice Request a withdrawal by specifying the amount of stv to withdraw, burning stETH shares and rebalancing
     * @param _stvToWithdraw The amount of stv to withdraw (27 decimals)
     * @param _stethSharesToBurn The amount of stETH shares to burn to repay user's liabilities (18 decimals)
     * @param _stethSharesToRebalance The amount of stETH shares to rebalance (18 decimals)
     * @return requestId The ID of the withdrawal request
     */
    function requestWithdrawal(
        uint256 _stvToWithdraw,
        uint256 _stethSharesToBurn,
        uint256 _stethSharesToRebalance
    ) public virtual returns (uint256 requestId) {
        requestId = _requestWithdrawalQueue(
            msg.sender,
            msg.sender,
            _stvToWithdraw,
            _stethSharesToBurn,
            _stethSharesToRebalance
        );
    }

    function _requestWithdrawalQueue(
        address _owner,
        address _receiver,
        uint256 _stvToWithdraw,
        uint256 _stethSharesToBurn,
        uint256 _stethSharesToRebalance
    ) internal returns (uint256 requestId) {
        if (_stvToWithdraw == 0) revert WrapperBase.ZeroStvShares();

        if (_stethSharesToBurn > 0) {
            _burnStethShares(_owner, _stethSharesToBurn);
        }

        if (_stethSharesToRebalance > 0) {
            /// @dev User's liability in the amount of _stethSharesToRebalance is transferred to the Withdrawal Queue,
            /// and _stvToWithdraw serves as collateral for this liability
            uint256 minStvAmount = _calcStvToLockForStethShares(_stethSharesToRebalance); // TODO: can it be the force rebalance threshold?
            if (_stvToWithdraw < minStvAmount) revert InsufficientStv();
            _transferMintedStethShares(_owner, address(WITHDRAWAL_QUEUE), _stethSharesToRebalance);
        }

        _transfer(_owner, address(WITHDRAWAL_QUEUE), _stvToWithdraw);
        requestId = WITHDRAWAL_QUEUE.requestWithdrawal(_stvToWithdraw, _stethSharesToRebalance, _receiver);
    }

    // =================================================================================
    // EFFECTIVE ASSETS
    // =================================================================================

    /**
     * @notice Total effective assets managed by the wrapper
     * @return effectiveAssets Total effective assets (18 decimals)
     * @dev Includes totalAssets + total exceeding minted stETH shares
     */
    function totalEffectiveAssets() public view override returns (uint256 effectiveAssets) {
        effectiveAssets = totalAssets() + totalExceedingMintedSteth();
    }

    /**
     * @notice Effective assets of a specific account
     * @param _account The address of the account
     * @return effectiveAssets Effective assets of the account (18 decimals)
     */
    function effectiveAssetsOf(address _account) public view override returns (uint256 effectiveAssets) {
        /// As a result of the rebalancing initiated in the Staking Vault, bypassing the Wrapper,
        /// part of the total liability can be reduced at the expense of the Staking Vault's assets.
        ///
        /// As a result of this operation, the total liabilityShares on the Staking Vault will decrease,
        /// while mintedStethShares will remain the same, as will the users' debts on these obligations.
        /// The difference between these two values is the stETH that users owe to Wrapper, but which
        /// should not be returned to Staking Vault, but should be distributed among all participants
        /// in exchange for the withdrawn ETH.
        ///
        /// Thus, in rare situations, Staking Vault may have two assets: ETH and stETH, which are
        /// distributed among all users in proportion to their shares.
        effectiveAssets = assetsOf(_account) + exceedingMintedStethOf(_account);
    }

    // =================================================================================
    // MINTED STETH SHARES
    // =================================================================================

    /**
     * @notice Total stETH shares minted by the wrapper
     * @return stethShares Total stETH shares minted (18 decimals)
     */
    function totalMintedStethShares() public view returns (uint256 stethShares) {
        stethShares = _getWrapperBStorage().totalMintedStethShares;
    }

    /**
     * @notice Amount of stETH shares minted by the wrapper for a specific account
     * @param _account The address of the account
     * @return stethShares Amount of stETH shares minted (18 decimals)
     */
    function mintedStethSharesOf(address _account) public view returns (uint256 stethShares) {
        stethShares = _getWrapperBStorage().mintedStethShares[_account];
    }

    /**
     * @notice Total Staking Vault minting capacity in stETH shares
     * @return stethShares Total minting capacity in stETH shares
     */
    function totalMintingCapacityShares() public view returns (uint256 stethShares) {
        stethShares = DASHBOARD.totalMintingCapacityShares();
    }

    /**
     * @notice Remaining Staking Vault minting capacity in stETH shares
     * @return stethShares Remaining minting capacity in stETH shares
     * @dev Can be limited by Vault's max capacity
     */
    function remainingMintingCapacityShares(uint256 _ethToFund) public view returns (uint256 stethShares) {
        stethShares = DASHBOARD.remainingMintingCapacityShares(_ethToFund);
    }

    /**
     * @notice Calculate the minting capacity in stETH shares for a specific account
     * @param _account The address of the account
     * @return stethSharesCapacity The minting capacity in stETH shares
     */
    function mintingCapacitySharesOf(address _account) public view returns (uint256 stethSharesCapacity) {
        uint256 stethSharesForAssets = _calcStethSharesToMintForAssets(effectiveAssetsOf(_account));
        stethSharesCapacity = Math.saturatingSub(stethSharesForAssets, mintedStethSharesOf(_account));
    }

    // TODO: remove
    function mintableStethShares(address _account) public view returns (uint256 stethShares) {
        stethShares = mintingCapacitySharesOf(_account);
    }

    /**
     * @notice Mint stETH shares up to the user's minting capacity
     * @param _stethShares The amount of stETH shares to mint
     */
    function mintStethShares(uint256 _stethShares) public {
        _mintStethShares(msg.sender, _stethShares);
    }

    function _mintStethShares(address _account, uint256 _stethShares) internal {
        if (_stethShares == 0) revert ZeroArgument();
        if (mintingCapacitySharesOf(_account) < _stethShares) revert InsufficientMintingCapacity();

        DASHBOARD.mintShares(_account, _stethShares);

        WrapperBStorage storage $ = _getWrapperBStorage();
        $.totalMintedStethShares += _stethShares;
        $.mintedStethShares[_account] += _stethShares;

        emit StethSharesMinted(_account, _stethShares);
    }

    /**
     * @notice Burn stETH shares to reduce the user's minted stETH obligation
     * @param _stethShares The amount of stETH shares to burn
     */
    function burnStethShares(uint256 _stethShares) public {
        _burnStethShares(msg.sender, _stethShares);
    }

    function _burnStethShares(address _account, uint256 _stethShares) internal {
        _decreaseMintedStethShares(_account, _stethShares);

        STETH.transferSharesFrom(_account, address(this), _stethShares);
        DASHBOARD.burnShares(_stethShares);
    }

    function _decreaseMintedStethShares(address _account, uint256 _stethShares) internal {
        WrapperBStorage storage $ = _getWrapperBStorage();

        if (_stethShares == 0) revert ZeroArgument();
        if ($.mintedStethShares[_account] < _stethShares) revert InsufficientMintedShares();

        $.totalMintedStethShares -= _stethShares;
        $.mintedStethShares[_account] -= _stethShares;

        emit StethSharesBurned(_account, _stethShares);
    }

    function _transferMintedStethShares(address _from, address _to, uint256 _stethShares) internal {
        WrapperBStorage storage $ = _getWrapperBStorage();

        if (_stethShares == 0) revert ZeroArgument();
        if ($.mintedStethShares[_from] < _stethShares) revert InsufficientMintedShares();

        $.mintedStethShares[_from] -= _stethShares;
        $.mintedStethShares[_to] += _stethShares;

        emit StethSharesBurned(_from, _stethShares);
        emit StethSharesMinted(_to, _stethShares);
    }

    /**
     * @dev Use the ceiling rounding to ensure enough assets are locked
     */
    function _calcReservedAssetsPart(uint256 _assets) internal view returns (uint256 assetsToReserve) {
        assetsToReserve = Math.mulDiv(_assets, WRAPPER_RR_BP, TOTAL_BASIS_POINTS, Math.Rounding.Ceil);
    }

    function _calcUnreservedAssetsPart(uint256 _assets) internal view returns (uint256 assetsToReserve) {
        assetsToReserve = Math.mulDiv(
            _assets,
            TOTAL_BASIS_POINTS - WRAPPER_RR_BP,
            TOTAL_BASIS_POINTS,
            Math.Rounding.Floor
        );
    }

    function _calcStethSharesToMintForAssets(uint256 _assets) internal view returns (uint256 stethShares) {
        stethShares = STETH.getSharesByPooledEth(_calcUnreservedAssetsPart(_assets));
    }

    function _calcStethSharesToMintForStv(uint256 _stv) internal view returns (uint256 stethShares) {
        stethShares = _calcStethSharesToMintForAssets(_convertToAssets(_stv));
    }

    /**
     * @dev Use the ceiling rounding to ensure enough assets are locked
     */
    function _calcAssetsToLockForStethShares(uint256 _stethShares) internal view returns (uint256 assetsToLock) {
        if (_stethShares == 0) return 0;
        uint256 steth = STETH.getPooledEthBySharesRoundUp(_stethShares);
        assetsToLock = Math.mulDiv(steth, TOTAL_BASIS_POINTS, TOTAL_BASIS_POINTS - WRAPPER_RR_BP, Math.Rounding.Ceil);
    }

    function _calcStvToLockForStethShares(uint256 _stethShares) internal view returns (uint256 stvToLock) {
        uint256 assetsToLock = _calcAssetsToLockForStethShares(_stethShares);
        stvToLock = _convertToShares(assetsToLock, Math.Rounding.Ceil);
    }

    // =================================================================================
    // EXCEEDING MINTED STETH
    // =================================================================================

    /**
     * @notice Amount of minted stETH shares exceeding the Staking Vault's liability
     * @return stethShares Amount of exceeding stETH shares (18 decimals)
     * @dev May occur if rebalancing happens on the Staking Vault bypassing the Wrapper
     */
    function totalExceedingMintedStethShares() public view returns (uint256 stethShares) {
        uint256 totalMinted = totalMintedStethShares();
        uint256 totalLiability = DASHBOARD.liabilityShares();

        if (totalMinted <= totalLiability) return 0;
        stethShares = totalMinted - totalLiability;
    }

    /**
     * @notice Amount of minted stETH exceeding the Staking Vault's liability
     * @return steth Amount of exceeding stETH (18 decimals)
     * @dev May occur if rebalancing happens on the Staking Vault bypassing the Wrapper
     */
    function totalExceedingMintedSteth() public view override returns (uint256 steth) {
        steth = STETH.getPooledEthByShares(totalExceedingMintedStethShares());
    }

    /**
     * @notice Amount of stETH shares exceeding the Staking Vault's liability for a specific account
     * @param _account The address of the account
     * @return stethShares Amount of exceeding stETH shares (18 decimals)
     * @dev May occur if rebalancing happens on the Staking Vault bypassing the Wrapper
     */
    function exceedingMintedStethSharesOf(address _account) public view returns (uint256 stethShares) {
        uint256 totalExceeding = totalExceedingMintedStethShares();
        uint256 totalSupply = totalSupply();

        if (totalExceeding == 0 || totalSupply == 0) return 0;
        stethShares = Math.mulDiv(totalExceeding, balanceOf(_account), totalSupply, Math.Rounding.Floor);
    }

    /**
     * @notice Amount of stETH exceeding the Staking Vault's liability for a specific account
     * @param _account The address of the account
     * @return steth Amount of exceeding stETH (18 decimals)
     * @dev May occur if rebalancing happens on the Staking Vault bypassing the Wrapper
     */
    function exceedingMintedStethOf(address _account) public view returns (uint256 steth) {
        steth = STETH.getPooledEthByShares(exceedingMintedStethSharesOf(_account));
    }

    // =================================================================================
    // UNASSIGNED LIABILITY
    // =================================================================================

    /**
     * @notice Total unassigned liability shares in the Staking Vault
     * @return unassignedLiabilityShares Total unassigned liability shares (18 decimals)
     * @dev Overridden method from WrapperBase to include unassigned liability shares
     * @dev May occur if liability was transferred from another Staking Vault
     */
    function totalUnassignedLiabilityShares() public view override returns (uint256 unassignedLiabilityShares) {
        uint256 totalMinted = totalMintedStethShares();
        uint256 totalLiability = DASHBOARD.liabilityShares();

        if (totalMinted >= totalLiability) return 0;
        unassignedLiabilityShares = totalLiability - totalMinted;
    }

    // =================================================================================
    // REBALANCE
    // =================================================================================

    /**
     * @notice Rebalance the user's minted stETH shares by burning stvETH shares
     * @param _stethShares The amount of stETH shares to rebalance
     * @dev First, rebalances internally by burning stvETH shares, which decreases exceeding shares (if any)
     * @dev Second, if there are remaining liability shares, rebalances Staking Vault
     * @dev Requires fresh oracle report, which is checked in the Withdrawal Queue
     */
    function rebalanceMintedStethShares(uint256 _stethShares, uint256 _maxStvToBurn) public {
        _checkOnlyWithdrawalQueue();

        if (_stethShares == 0) revert ZeroArgument();
        if (_stethShares > mintedStethSharesOf(msg.sender)) revert InsufficientMintedShares();

        uint256 exceedingStethShares = totalExceedingMintedStethShares();
        uint256 remainingStethShares = Math.saturatingSub(_stethShares, exceedingStethShares);

        if (remainingStethShares > 0) DASHBOARD.rebalanceVaultWithShares(remainingStethShares);

        uint256 ethToRebalance = STETH.getPooledEthBySharesRoundUp(_stethShares);
        uint256 stvToBurn = _convertToShares(ethToRebalance, Math.Rounding.Ceil);

        if (stvToBurn > _maxStvToBurn) {
            emit SocializedLoss(stvToBurn - _maxStvToBurn, ethToRebalance - _convertToAssets(_maxStvToBurn));
            stvToBurn = _maxStvToBurn;
        }

        emit StethSharesRebalanced(_stethShares, stvToBurn);

        _decreaseMintedStethShares(msg.sender, _stethShares);
        _burn(msg.sender, stvToBurn);
    }

    // =================================================================================
    // ERC20 overrides
    // =================================================================================

    /**
     * @dev Overridden method from ERC20 to include reserve ratio check
     * @dev Ensures that after any transfer, the sender still has enough reserved balance for their minted stETH shares
     */
    function _update(address _from, address _to, uint256 _value) internal override {
        super._update(_from, _to, _value);

        uint256 mintedStethShares = mintedStethSharesOf(_from);
        if (mintedStethShares == 0) return;

        uint256 stvToLock = _calcStvToLockForStethShares(mintedStethShares);
        if (balanceOf(_from) < stvToLock) revert InsufficientReservedBalance();
    }

    // TODO: transfer with debt? do we need it?
    // TODO: force rebalance for specific user
}
