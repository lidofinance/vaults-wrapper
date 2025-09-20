// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {console} from "forge-std/Test.sol";

import {WrapperBase} from "./WrapperBase.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IStETH} from "./interfaces/IStETH.sol";

/**
 * @title WrapperB
 * @notice Configuration B: Minting, no strategy - stvETH shares + maximum stETH minting for user
 */
contract WrapperB is WrapperBase {

    error InsufficientSharesLocked(address user);
    error InsufficientMintableStShares();
    error ZeroArgument();
    error MintingForThanTargetStSharesShareIsNotAllowed();
    error TodoError();

    IStETH public immutable STETH;
    uint256 public immutable WRAPPER_RR_BP; // vault's reserve ratio plus gap for wrapper

    /// @custom:storage-location erc7201:wrapper.b.storage
    // TODO: maybe count stShares in E27 as well
    struct WrapperBStorage {
        mapping(address => uint256) stShares;
        uint256 totalStShares;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.b.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_B_STORAGE_LOCATION = 0x68280b7606a1a98bf19dd7ad4cb88029b355c2c81a554f53b998c73f934e4400;

    constructor(
        address _dashboard,
        address _stETH,
        bool _allowListEnabled,
        uint256 _reserveRatioGapBP,
        address _withdrawalQueue
    ) WrapperBase(_dashboard, _allowListEnabled, _withdrawalQueue) {
        STETH = IStETH(_stETH);

        uint256 vaultRR = DASHBOARD.reserveRatioBP();
        require(_reserveRatioGapBP < TOTAL_BASIS_POINTS - vaultRR, "Reserve ratio gap too high");
        WRAPPER_RR_BP = vaultRR + _reserveRatioGapBP;
    }

    //
    // Deposit and mint functions
    //

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Deposits and mints maximum stETH to user
     * @param _receiver Address to receive the minted shares
     * @return stv Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral) public payable virtual override returns (uint256 stv) {
        uint256 targetStethShares = _calcTargetStethSharesAmount(msg.value);
        stv = depositETH(_receiver, _referral, targetStethShares);
    }

    function depositETH(address _receiver, address _referral, uint256 _stethSharesToMint) public payable returns (uint256 stv) {
        stv = _deposit(_receiver, _referral);

        uint256 maxStethShares = _calcYetMintableStethShares(_receiver);
        uint256 targetStethShares = _calcTargetStethSharesAmount(msg.value);

        if (_stethSharesToMint > targetStethShares) revert MintingForThanTargetStSharesShareIsNotAllowed();
        if (_stethSharesToMint > maxStethShares) revert InsufficientMintableStShares();

        if (_stethSharesToMint > 0) {
            _mintStethShares(_receiver, _stethSharesToMint);
        }
    }

    //
    // Withdrawal functions
    //

    function withdrawableEth(address _address, uint256 _stv, uint256 _stethSharesToBurn) public view returns (uint256 ethAmount) {
        (, uint256 userEthWithdrawableWithoutBurning) = _calcWithdrawableWithoutBurning(_address);
        uint256 userEthRequiringBurning = _convertToAssets(_stv) - userEthWithdrawableWithoutBurning;

        ethAmount = userEthWithdrawableWithoutBurning +
            Math.mulDiv(_stethSharesToBurn, userEthRequiringBurning, _getStethShares(_address), Math.Rounding.Floor);
    }

    function withdrawableStv(address _address, uint256 _stethSharesToBurn) public view returns (uint256 stv) {
        uint256 userStv = balanceOf(_address);
        uint256 eth = withdrawableEth(_address, userStv, _stethSharesToBurn);
        stv = Math.mulDiv(eth, userStv, _convertToAssets(userStv), Math.Rounding.Floor);
    }

    function getStethShares(address _address) public view returns (uint256 stethShares) {
        return _getStethShares(_address);
    }

    /**
     * @notice Calculate the amount of stETH shares required for a given amount of stvETH shares to withdraw
     * @param _stv The amount of stvETH shares to withdraw
     * @return stethShares The corresponding amount of stETH shares needed for withdrawal
     */
    function stethSharesForWithdrawal(address _address, uint256 _stv) public view returns (uint256 stethShares) {
        if (_stv == 0) return 0;

        uint256 balance = balanceOf(_address);
        if (balance == 0) return 0; // TODO: revert here?

        (uint256 stvWithdrawableWithoutBurning, ) = _calcWithdrawableWithoutBurning(_address);

        uint256 stvRequiringBurning = Math.saturatingSub(_stv, stvWithdrawableWithoutBurning);

        // TODO: Ceil or Floor?
        stethShares = Math.mulDiv(stvRequiringBurning, _getStethShares(_address), balance, Math.Rounding.Ceil);
    }

    function mintableStethShares(address _address) external view returns (uint256 stethShares) {
        return _calcYetMintableStethShares(_address);
    }

    function _calcWithdrawableWithoutBurning(address _address) internal view returns (uint256 stv, uint256 ethAmount) {
        uint256 vaultWithdrawableEth = totalAssets() - DASHBOARD.locked();
        uint256 totalUserStv = balanceOf(_address);
        ethAmount = _getPartCorrespondingToStv(totalUserStv, vaultWithdrawableEth);
        stv = Math.mulDiv(ethAmount, totalUserStv, _convertToAssets(totalUserStv), Math.Rounding.Floor);
    }

    function _calcYetMintableStethShares(address _address) public view returns (uint256 stethShares) {
        uint256 stvEth = _convertToAssets(balanceOf(_address));

        uint256 reserveEth = Math.mulDiv(stvEth, WRAPPER_RR_BP, TOTAL_BASIS_POINTS, Math.Rounding.Floor);
        uint256 vaultRemainingMintingCapacity = DASHBOARD.remainingMintingCapacityShares(0);

        uint256 stethSharesForUnreservedEth = STETH.getSharesByPooledEth(stvEth - reserveEth);
        uint256 notMintedStethShares = Math.saturatingSub(stethSharesForUnreservedEth, _getStethShares(_address));

        stethShares = Math.min(notMintedStethShares, vaultRemainingMintingCapacity);
    }

    function mintStethShares(uint256 _stethShares) external {
        uint256 mintableStShares_ = _calcYetMintableStethShares(msg.sender);
        if (mintableStShares_ < _stethShares) revert InsufficientMintableStShares();

        _mintStethShares(msg.sender, _stethShares);
    }

    // TODO: add request as ether as arg (not stvShares)
    function requestWithdrawal(uint256 _stv) public virtual returns (uint256 requestId) {
        if (_stv == 0) revert WrapperBase.ZeroStvShares();

        // TODO: move min max withdrawal amount check from WQ here?

        WithdrawalQueue withdrawalQueue = WITHDRAWAL_QUEUE;

        uint256 stethShares = stethSharesForWithdrawal(msg.sender, _stv);

        _transfer(msg.sender, address(this), _stv);

        if (stethShares > 0) {
            STETH.transferSharesFrom(msg.sender, address(this), stethShares);
            _burnStethShares(stethShares);
        }

        // NB: needed to transfer to Wrapper first to do the math correctly
        _transfer(address(this), address(withdrawalQueue), _stv);

        requestId = withdrawalQueue.requestWithdrawal(_stv, msg.sender);
    }

    //
    // Calculation helpers
    //

    function _calcTargetStethSharesAmount(uint256 _eth) internal view returns (uint256 stethShares) {
        uint256 notReservedEth = Math.mulDiv(_eth, TOTAL_BASIS_POINTS - WRAPPER_RR_BP, TOTAL_BASIS_POINTS, Math.Rounding.Floor);
        stethShares = STETH.getSharesByPooledEth(notReservedEth);
    }

    function _calcStShares(address _address, uint256 _stv) internal view returns (uint256 stShares) {
        uint256 balance = balanceOf(_address);
        if (balance == 0) return 0;

        // TODO: replace by assert
        if (balance < _stv) revert InsufficientSharesLocked(_address);

        // TODO: how to round here?
        stShares = Math.mulDiv(_stv, _getStShares(_address), balance, Math.Rounding.Ceil);
    }

    //
    // ERC20 overrides
    //

    function _update(address _from, address _to, uint256 _value) internal override {
        // TODO: maybe add workaround for _from == address(0) because ERC20 minting is _update from address(0)
        _updateStShares(_from, _to, _value);
        super._update(_from, _to, _value);
    }

    //
    //
    //

    function _updateStShares(address _from, address _to, uint256 _stvToMove) internal {
        // if (_from == address(0) || _to == address(0) || _stvSharesMoved == 0) revert ZeroArgument();

        uint256 stSharesToMove = _calcStShares(_from, _stvToMove);

        // Don't update stShares if the sender has no stShares to move
        WrapperBStorage storage $ = _getWrapperBStorage();
        // if ($.stShares[_from] == 0) return;

        if (stSharesToMove == 0) return;

        $.stShares[_from] -= stSharesToMove;
        $.stShares[_to] += stSharesToMove;
    }

    function _mintStethShares(address _receiver, uint256 _stethShares) internal {
        if (_stethShares == 0) revert ZeroArgument();
        if (_receiver == address(0)) revert ZeroArgument();

        DASHBOARD.mintShares(_receiver, _stethShares);

        WrapperBStorage storage $ = _getWrapperBStorage();

        uint256 vaultStethShares = DASHBOARD.liabilityShares();
        uint256 totalStShares = $.totalStShares;

        // return;
        uint256 newStShares;
        if (totalStShares == 0) {
            newStShares = _stethShares;
        } else {
            newStShares = Math.mulDiv(vaultStethShares, totalStShares, vaultStethShares - _stethShares, Math.Rounding.Floor) - totalStShares;
        }

        $.totalStShares += newStShares;
        $.stShares[_receiver] += newStShares;
    }

    function _burnStethShares(uint256 _stethShares) internal {
        if (_stethShares == 0) revert ZeroArgument();
        uint256 vaultLiabilityShares = DASHBOARD.liabilityShares();
        if (vaultLiabilityShares == 0) revert TodoError();

        WrapperBStorage storage $ = _getWrapperBStorage();

        uint256 stShares = Math.mulDiv(_stethShares, $.totalStShares, vaultLiabilityShares, Math.Rounding.Floor);

        $.stShares[address(this)] -= stShares;
        $.totalStShares -= stShares;

        STETH.approve(address(DASHBOARD), STETH.getPooledEthByShares(_stethShares));
        DASHBOARD.burnShares(_stethShares);
    }

    function _getStShares(address _address) internal view returns (uint256 stShares) {
        stShares = _getWrapperBStorage().stShares[_address];
    }
    function _getStethShares(address _address) internal view returns (uint256 stethShares) {
        uint256 totalStShares = _getWrapperBStorage().totalStShares;
        if (totalStShares == 0) return 0;
        return Math.mulDiv(_getStShares(_address), DASHBOARD.liabilityShares(), totalStShares, Math.Rounding.Floor);

    }

    function _getPartCorrespondingToStShares(uint256 _stShares, uint256 _assets, address _address) internal view returns (uint256 assets) {
        assets = Math.mulDiv(_stShares, _assets, _getStShares(_address), Math.Rounding.Floor);
    }

    function _getPartCorrespondingToStv(uint256 _stv, uint256 _assets) internal view returns (uint256 assets) {
        assets = Math.mulDiv(_stv, _assets, totalSupply(), Math.Rounding.Floor);
    }

    function _getWrapperBStorage() private pure returns (WrapperBStorage storage $) {
        assembly {
            $.slot := WRAPPER_B_STORAGE_LOCATION
        }
    }

}