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

    IStETH public immutable STETH;
    uint256 public immutable RESERVE_RATIO_BP;

    struct UserBalance {
        uint256 stvShares;
        uint256 stShares;
    }

    /// @custom:storage-location erc7201:wrapper.b.storage
    struct WrapperBStorage {
        mapping(address => UserBalance) userBalances;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.b.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_B_STORAGE_LOCATION = 0x8b02b285f37f4c4e7363a6c05f1d4e1c643f738200b8c0d4094f8c34b67b3b00; // TODO: check the hash

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

        // DASHBOARD.grantRole(DASHBOARD.MINT_ROLE(), address(this));
        // DASHBOARD.grantRole(DASHBOARD.BURN_ROLE(), address(this));
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Deposits and mints maximum stETH to user
     * @param _receiver Address to receive the minted shares
     * @return stvShares Number of stvETH shares minted
     */
    function depositETH(address _receiver) public payable override returns (uint256 stvShares) {
        if (msg.value == 0) revert WrapperBase.ZeroDeposit();
        if (_receiver == address(0)) revert WrapperBase.InvalidReceiver();
        _checkAllowList();

        DASHBOARD.fund{value: msg.value}();

        stvShares = previewDeposit(msg.value);
        _mint(_receiver, stvShares);

        uint256 stShares = _mintMaximumStETH(_receiver, stvShares);

        WrapperBStorage storage $ = _getWrapperBStorage();
        UserBalance memory userBalance = $.userBalances[_receiver];
        userBalance = UserBalance({
            stvShares: stvShares + userBalance.stvShares,
            stShares: stShares + userBalance.stShares
        });
        $.userBalances[_receiver] = userBalance;

        emit Deposit(msg.sender, _receiver, msg.value, stvShares);
    }

    /**
     * @notice Calculate the amount of stETH shares required for a given amount of stvETH shares to withdraw
     * @param _stvShares The amount of stvETH shares to withdraw
     * @return stShares The corresponding amount of stETH shares needed for withdrawal
     */
    function stSharesForWithdrawal(uint256 _stvShares) public view returns (uint256 stShares) {
        if (_stvShares == 0) return 0;

        WrapperBStorage storage $ = _getWrapperBStorage();
        uint256 userStvShares = $.userBalances[msg.sender].stvShares;
        if (userStvShares == 0) return 0;

        uint256 userStShares = $.userBalances[msg.sender].stShares;

        stShares = Math.mulDiv(_stvShares, userStShares, userStvShares, Math.Rounding.Ceil); // TODO: Ceil or Floor?
    }

    function stSharesToReturn() public view returns (uint256 stShares) {
        WrapperBStorage storage $ = _getWrapperBStorage();
        stShares = $.userBalances[msg.sender].stShares;
    }


    // TODO: add request as ether as arg (not stvShares)
    function requestWithdrawal(uint256 _stvShares) external virtual returns (uint256 requestId) {
        if (_stvShares == 0) revert WrapperBase.ZeroStvShares();

        WithdrawalQueue withdrawalQueue = withdrawalQueue();

        uint256 stShares = stSharesForWithdrawal(_stvShares);

        STETH.transferSharesFrom(msg.sender, address(this), stShares);

        _transfer(msg.sender, address(withdrawalQueue), _stvShares);

        STETH.approve(address(DASHBOARD), STETH.getPooledEthByShares(stShares));
        DASHBOARD.burnShares(stShares);

        WrapperBStorage storage $ = _getWrapperBStorage();
        $.userBalances[msg.sender].stShares -= stShares;
        $.userBalances[msg.sender].stvShares -= _stvShares;

        requestId = withdrawalQueue.requestWithdrawal(msg.sender, _convertToAssets(_stvShares));
    }

    function _calcMaxMintableStETHSharesForDeposit(uint256 _ethDeposited) public view returns (uint256 stShares) {
        uint256 a = Math.mulDiv(_ethDeposited, RESERVE_RATIO_BP, TOTAL_BASIS_POINTS, Math.Rounding.Floor);
        return STETH.getSharesByPooledEth(_ethDeposited - a);
    }

    function _mintMaximumStETH(address _receiver, uint256 _stvShares) internal returns (uint256 stShares) {
        uint256 usersEth = _convertToAssets(_stvShares);

        stShares = Math.min(_calcMaxMintableStETHSharesForDeposit(usersEth), DASHBOARD.remainingMintingCapacityShares(0));

        if (stShares == 0) revert NoMintingCapacityAvailable();

        DASHBOARD.mintShares(_receiver, stShares);
    }

}