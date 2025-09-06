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

    IStETH public immutable STETH;
    uint256 public immutable RESERVE_RATIO_BP;

    /// @custom:storage-location erc7201:wrapper.b.storage
    struct WrapperBStorage {
        mapping(address => uint256) stShares;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.b.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_B_STORAGE_LOCATION = 0x68280b7606a1a98bf19dd7ad4cb88029b355c2c81a554f53b998c73f934e4400;

    function _getWrapperBStorage() private pure returns (WrapperBStorage storage $) {
        assembly {
            $.slot := WRAPPER_B_STORAGE_LOCATION
        }
    }

    constructor(
        address _dashboard,
        address _stETH,
        bool _allowListEnabled
    ) WrapperBase(_dashboard, _allowListEnabled) {
        STETH = IStETH(_stETH);

        RESERVE_RATIO_BP = DASHBOARD.reserveRatioBP();
    }

    function initialize(
        address _owner,
        string memory _name,
        string memory _symbol
    ) public override initializer {
        WrapperBase.initialize(_owner, _name, _symbol);
    }

    //
    // Deposit and mint functions
    //

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Deposits and mints maximum stETH to user
     * @param _receiver Address to receive the minted shares
     * @return stvShares Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral) public payable virtual override returns (uint256 stvShares) {
        stvShares = _deposit(_receiver, _referral);
        _mintMaximumStShares(_receiver, stvShares);
    }

    //
    // Withdrawal functions
    //

    function withdrawableEth(address _address, uint256 _stvShares, uint256 _stSharesToBurn) public view returns (uint256 ethAmount) {
        // TODO
        // Math.mulDiv(_stvShares, balanceOf(_address), totalSupply(), Math.Rounding.Floor);
    }

    function stSharesToBurnToWithdraw(address _address, uint256 _stvShares) public view returns (uint256 stSharesToBurn) {
        // TODO
    }

    /**
     * @notice Calculate the amount of stETH shares required for a given amount of stvETH shares to withdraw
     * @param _stvShares The amount of stvETH shares to withdraw
     * @return stShares The corresponding amount of stETH shares needed for withdrawal
     */
    function stSharesForWithdrawal(address _address, uint256 _stvShares) public view returns (uint256 stShares) {
        if (_stvShares == 0) return 0;

        uint256 balance = balanceOf(_address);
        if (balance == 0) return 0;

        // TODO: Ceil or Floor?
        stShares = Math.mulDiv(_stvShares, _getStShares(_address), balance, Math.Rounding.Ceil);
    }

    function mintableStShares(address _address) public view returns (uint256 stShares) {
        uint256 stvShares = balanceOf(_address);
        uint256 usersEth = previewRedeem(stvShares);
        uint256 maxMintable = _calcMaxMintableStShares(usersEth);
        uint256 alreadyMinted = stSharesForWithdrawal(_address, stvShares);

        if (alreadyMinted >= maxMintable) return 0;

        stShares = maxMintable - alreadyMinted;
    }


    function mintStShares(uint256 _stShares) external returns (uint256 stShares) {
        uint256 mintableStShares_ = mintableStShares(msg.sender);
        if (mintableStShares_ < _stShares) revert InsufficientMintableStShares();
        stShares = _mintStShares(msg.sender, _stShares);
    }

    // TODO: add request as ether as arg (not stvShares)
    function requestWithdrawal(uint256 _stvShares) external virtual returns (uint256 requestId) {
        if (_stvShares == 0) revert WrapperBase.ZeroStvShares();

        WithdrawalQueue withdrawalQueue = withdrawalQueue();

        uint256 stShares = stSharesForWithdrawal(msg.sender, _stvShares);

        _transfer(msg.sender, address(this), _stvShares);

        STETH.transferSharesFrom(msg.sender, address(this), stShares);
        _burnStShares(stShares);

        // NB: need to transfer to Wrapper first to do the math correctly
        _transfer(address(this), address(withdrawalQueue), _stvShares);

        requestId = withdrawalQueue.requestWithdrawal(_stvShares, msg.sender);
    }

    //
    // Calculation helpers
    //

    function _calcStShares(uint256 _stvShares, address _address) internal view returns (uint256 stShares) {
        uint256 balance = balanceOf(_address);
        if (balance == 0) return 0;

        // TODO: replace by assert
        if (balance < _stvShares) revert InsufficientSharesLocked(_address);

        // TODO: how to round here?
        stShares = Math.mulDiv(_stvShares, _getStShares(_address), balance, Math.Rounding.Ceil);
    }

    function _getStShares(address _address) internal view returns (uint256 stShares) {
        WrapperBStorage storage $ = _getWrapperBStorage();
        stShares = $.stShares[_address];
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

    function _updateStShares(address _from, address _to, uint256 _stvSharesToMove) internal {
        // if (_from == address(0) || _to == address(0) || _stvSharesMoved == 0) revert ZeroArgument();

        uint256 stSharesToMove = _calcStShares(_stvSharesToMove, _from);

        // Don't update stShares if the sender has no stShares to move
        WrapperBStorage storage $ = _getWrapperBStorage();
        // if ($.stShares[_from] == 0) return;

        if (stSharesToMove == 0) return;

        $.stShares[_from] -= stSharesToMove;
        $.stShares[_to] += stSharesToMove;
    }

    function _burnStShares(uint256 _stShares) internal {
        if (_stShares == 0) revert ZeroArgument();

        WrapperBStorage storage $ = _getWrapperBStorage();
        $.stShares[address(this)] -= _stShares;
        STETH.approve(address(DASHBOARD), STETH.getPooledEthByShares(_stShares));
        DASHBOARD.burnShares(_stShares);
    }


    function _calcMaxMintableStShares(uint256 _eth) public view returns (uint256 stShares) {
        uint256 intermediateValue = Math.mulDiv(_eth, RESERVE_RATIO_BP, TOTAL_BASIS_POINTS, Math.Rounding.Floor);
        stShares = Math.min(
            STETH.getSharesByPooledEth(_eth - intermediateValue),
            DASHBOARD.remainingMintingCapacityShares(0)
        );
    }

    function _mintStShares(address _receiver, uint256 _stShares) internal returns (uint256 stShares) {
        if (_stShares == 0) revert ZeroArgument();
        if (_receiver == address(0)) revert ZeroArgument();

        stShares = _stShares;
        DASHBOARD.mintShares(_receiver, stShares);

        _getWrapperBStorage().stShares[_receiver] += stShares;
    }

    function _mintMaximumStShares(address _receiver, uint256 _stvShares) internal returns (uint256 stShares) {
        stShares = _calcMaxMintableStShares(_convertToAssets(_stvShares));
        _mintStShares(_receiver, stShares);
    }

}