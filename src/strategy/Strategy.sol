// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StvStETHPool} from "src/StvStETHPool.sol";
import {IStETH} from "src/interfaces/IStETH.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";
import {IWstETH} from "src/interfaces/IWstETH.sol";

abstract contract Strategy is AccessControlEnumerableUpgradeable, PausableUpgradeable, IStrategy {
    StvStETHPool public immutable POOL_;
    IStETH public immutable STETH;
    IWstETH public immutable WSTETH;
    address public immutable STRATEGY_CALL_FORWARDER_IMPL;

    /// @dev WARNING: This ID is used to calculate user proxy addresses.
    /// Changing this value will break user proxy address calculations.
    bytes32 public constant STRATEGY_ID = keccak256("strategy.ggv.v1");

    // ACL
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");

    /// @custom:storage-location erc7201:pool.storage.Strategy
    struct StrategyStorage {
        mapping(bytes32 salt => address proxy) userStrategyCallForwarder;
    }

    // keccak256(abi.encode(uint256(keccak256("pool.storage.Strategy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STRATEGY_STORAGE_LOCATION =
        0xf27e3064d83f3ff75b2b8f1a9f4dda06aee756464659bfe6d7aafc35d4d8a400;

    function _getStrategyStorage() internal pure returns (StrategyStorage storage $) {
        assembly {
            $.slot := STRATEGY_STORAGE_LOCATION
        }
    }

    error ZeroArgument(string name);

    constructor(address _pool, address _stETH, address _wstETH, address _strategyCallForwarderImpl) {
        STETH = IStETH(_stETH);
        WSTETH = IWstETH(_wstETH);
        STRATEGY_CALL_FORWARDER_IMPL = _strategyCallForwarderImpl;
        POOL_ = StvStETHPool(payable(_pool));

        _disableInitializers();
    }

    function POOL() external view returns (address) {
        return address(POOL_);
    }

    /// @notice Initialize the contract storage explicitly
    /// @param _admin Admin address that can change every role
    /// @dev Reverts if `_admin` equals to `address(0)`
    function initialize(address _admin) external initializer {
        if (_admin == address(0)) revert ZeroArgument("_admin");

        __AccessControlEnumerable_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // =================================================================================
    // PAUSE / RESUME
    // =================================================================================

    /**
     * @notice Pause withdrawal requests placement and finalization
     * @dev Does not affect claiming of already finalized requests
     */
    function pause() external {
        _checkRole(PAUSE_ROLE, msg.sender);
        _pause();
    }

    /**
     * @notice Resume withdrawal requests placement and finalization
     */
    function resume() external {
        _checkRole(RESUME_ROLE, msg.sender);
        _unpause();
    }

    // =================================================================================
    // RECOVERY
    // =================================================================================

    /// @notice Recovers ERC20 tokens from the strategy
    /// @param _token The token to recover
    /// @param _recipient The recipient of the tokens
    /// @param _amount The amount of tokens to recover
    function recoverERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        address proxy = getStrategyCallForwarderAddress(msg.sender);

        IStrategyCallForwarder(proxy)
            .call(address(STETH), abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _amount));
    }

    // =================================================================================
    // CALL FORWARDER
    // =================================================================================

    /// @notice Returns the address of the strategy proxy for a given user
    /// @param user The user for which to get the strategy call forwarder address
    /// @return callForwarder The address of the strategy call forwarder
    function getStrategyCallForwarderAddress(address user) public view returns (address callForwarder) {
        bytes32 salt = _generateSalt(user);
        callForwarder = Clones.predictDeterministicAddress(STRATEGY_CALL_FORWARDER_IMPL, salt);
    }

    function _getOrCreateCallForwarder(address _user) internal returns (address callForwarder) {
        if (_user == address(0)) revert ZeroArgument("_user");

        StrategyStorage storage $ = _getStrategyStorage();

        bytes32 salt = _generateSalt(_user);
        callForwarder = $.userStrategyCallForwarder[salt];
        if (callForwarder != address(0)) return callForwarder;

        callForwarder = Clones.cloneDeterministic(STRATEGY_CALL_FORWARDER_IMPL, salt);
        IStrategyCallForwarder(callForwarder).initialize(address(this));
        IStrategyCallForwarder(callForwarder)
            .call(address(STETH), abi.encodeWithSelector(STETH.approve.selector, address(POOL_), type(uint256).max));
        IStrategyCallForwarder(callForwarder)
            .call(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, address(POOL_), type(uint256).max));

        $.userStrategyCallForwarder[salt] = callForwarder;
    }

    function _generateSalt(address _user) internal view returns (bytes32 salt) {
        salt = keccak256(abi.encode(STRATEGY_ID, address(this), _user));
    }
}
