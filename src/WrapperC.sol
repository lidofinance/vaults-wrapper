// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";
import {WrapperB} from "./WrapperB.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

error InvalidConfiguration();
error PositionNotFound(uint256 positionId);
error PositionNotActive(uint256 positionId);
error PositionAlreadyExiting(uint256 positionId);
error InsufficientShares(uint256 required, uint256 available);

/**
 * @title WrapperC
 * @notice Configuration C: Minting and strategy - stvETH shares + strategy positions with stETH
 */
contract WrapperC is WrapperB {

    IStrategy public STRATEGY;

    struct Position {
        address user;
        uint256 stvETHShares;
        uint256 stETHAmount;
        bool isActive;
        bool isExiting;
        uint256 timestamp;
    }

    /// @custom:storage-location erc7201:wrapper.c.storage
    struct WrapperCStorage {
        uint256 nextPositionId;
        mapping(uint256 => Position) positions;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.c.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_C_STORAGE_LOCATION = 0xf3b72ddd31665ed6ad6084cdd9a0f3fc009d32c64759a1bb038cedb9e7165100;

    function _getWrapperCStorage() private pure returns (WrapperCStorage storage $) {
        assembly {
            $.slot := WRAPPER_C_STORAGE_LOCATION
        }
    }

    function nextPositionId() public view returns (uint256) {
        return _getWrapperCStorage().nextPositionId;
    }

    function positions(uint256 positionId) public view returns (Position memory) {
        return _getWrapperCStorage().positions[positionId];
    }

    event PositionOpened(
        address indexed user,
        uint256 indexed positionId,
        uint256 stvETHShares,
        uint256 stETHAmount
    );
    event PositionCloseRequested(
        address indexed user,
        uint256 indexed positionId
    );
    event PositionClosed(
        address indexed user,
        uint256 indexed positionId,
        uint256 stvETHShares
    );

    constructor(
        address _dashboard,
        address _stETH,
        bool _allowListEnabled,
        address _strategy
    ) WrapperB(_dashboard, _stETH, _allowListEnabled) {
        if (_strategy == address(0)) {
            revert InvalidConfiguration();
        }
        STRATEGY = IStrategy(_strategy);
    }

    // function initialize(
    //     address _owner,
    //     string memory _name,
    //     string memory _symbol
    // ) public override initializer {
    //     WrapperB.initialize(_owner, _name, _symbol);

    //     // Note: MINT_ROLE and BURN_ROLE should be granted by dashboard admin after deployment
    // }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Creates strategy position with minted stETH
     * @param _receiver Address to receive the minted shares
     * @return shares Number of stvETH shares minted
     */
    function depositETHToStrategy(address _receiver) public payable returns (uint256 shares) {
        if (msg.value == 0) revert WrapperBase.ZeroDeposit();
        if (_receiver == address(0)) revert WrapperBase.InvalidReceiver();

        // Check allowlist if enabled
        _checkAllowList();

        uint256 totalAssetsBefore = totalAssets();
        uint256 totalSupplyBefore = totalSupply();

        // Calculate shares before funding
        shares = previewDeposit(msg.value);

        // Fund vault through Dashboard
        DASHBOARD.fund{value: msg.value}();

        // Mint stvETH shares to receiver
        _mint(_receiver, shares);

        // Create strategy position
        _createStrategyPosition(_receiver, shares);

        emit Deposit(msg.sender, _receiver, msg.value, shares);

        assert(totalAssets() == totalAssetsBefore + msg.value);
        assert(totalSupply() == totalSupplyBefore + shares);

        return shares;
    }

    function _createStrategyPosition(address _user, uint256 _stvShares) internal returns (uint256 positionId) {
        uint256 stETHAmount = _mintMaximumStShares(address(STRATEGY), _stvShares);

        WrapperCStorage storage $ = _getWrapperCStorage();
        positionId = $.nextPositionId++;
        $.positions[positionId] = Position({
            user: _user,
            stvETHShares: _stvShares,
            stETHAmount: stETHAmount,
            isActive: true,
            isExiting: false,
            timestamp: block.timestamp
        });

        STRATEGY.execute(_user, stETHAmount);

        emit PositionOpened(_user, positionId, _stvShares, stETHAmount);
    }

    /**
     * @notice Request withdrawal for Configuration C (minting and strategy)
     * @param _positionId Position ID to withdraw/close
     */
    function requestWithdrawal(uint256 _positionId) external override returns (uint256 requestId) {
        Position storage position = _getWrapperCStorage().positions[_positionId];
        if (position.user != msg.sender) revert PositionNotFound(_positionId);
        if (!position.isActive) revert PositionNotActive(_positionId);
        if (position.isExiting) revert PositionAlreadyExiting(_positionId);

        position.isExiting = true;

        // Request strategy to initiate exit
        STRATEGY.initiateExit(msg.sender, position.stETHAmount);

        emit PositionCloseRequested(msg.sender, _positionId);
    }

    /**
     * @notice Finalize and claim withdrawal for Configuration C (minting and strategy)
     * @param _positionId Position ID to finalize and claim
     * @return requestId The withdrawal request ID for final claim
     */
    function finalizePositionWithdrawal(uint256 _positionId) external returns (uint256 requestId) {
        Position storage position = _getWrapperCStorage().positions[_positionId];
        if (position.user != msg.sender) revert PositionNotFound(_positionId);
        if (!position.isActive) revert PositionNotActive(_positionId);
        if (!position.isExiting) revert PositionNotActive(_positionId);

        // Finalize exit with strategy
        STRATEGY.finalizeExit(msg.sender);

        // Now proceed with normal withdrawal flow
        requestId = withdrawalQueue().requestWithdrawal(msg.sender, previewRedeem(position.stvETHShares));
        _burn(msg.sender, position.stvETHShares);

        // Mark position as closed
        position.isActive = false;

        emit PositionClosed(msg.sender, _positionId, position.stvETHShares);
    }

    /**
     * @notice Set the strategy address after construction
     * @dev This is needed to resolve circular dependency
     */
    // TODO: remove this function, set in initializer
    function setStrategy(address _strategy) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // Can only be set once if not set in constructor
        if (address(STRATEGY) == address(0)) {
            STRATEGY = IStrategy(_strategy);
        }
    }

    function getPosition(uint256 _positionId) external view returns (Position memory) {
        return _getWrapperCStorage().positions[_positionId];
    }

    function getUserPositions(address _user) external view returns (uint256[] memory) {
        WrapperCStorage storage $ = _getWrapperCStorage();
        uint256 count = 0;
        for (uint256 i = 0; i < $.nextPositionId; i++) {
            if ($.positions[i].user == _user && $.positions[i].isActive) {
                count++;
            }
        }

        uint256[] memory userPositions = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < $.nextPositionId; i++) {
            if ($.positions[i].user == _user && $.positions[i].isActive) {
                userPositions[index] = i;
                index++;
            }
        }

        return userPositions;
    }
}