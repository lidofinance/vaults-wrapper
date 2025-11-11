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
import {IWstETH} from "src/interfaces/IWstETH.sol";

abstract contract Strategy is AccessControlEnumerableUpgradeable, PausableUpgradeable, IStrategy {
    StvStETHPool public immutable POOL_;
    IStETH public immutable STETH;
    IWstETH public immutable WSTETH;

    // ACL
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");

    error ZeroArgument(string name);

    constructor(address _pool, address _stETH, address _wstETH) {
        STETH = IStETH(_stETH);
        WSTETH = IWstETH(_wstETH);
        POOL_ = StvStETHPool(payable(_pool));

        _disableInitializers();
    }

    function POOL() external view returns (address) {
        return address(POOL_);
    }

    /**
     * @notice Initialize the contract storage explicitly
     * @param _admin Admin address that can change every role
     * @dev Reverts if `_admin` equals to `address(0)`
     */
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

    /**
     * @notice Recovers ERC20 tokens from the strategy
     * @param _token The token to recover
     * @param _recipient The recipient of the tokens
     * @param _amount The amount of tokens to recover
     */
    function recoverERC20(address _token, address _recipient, uint256 _amount) external virtual override {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        IERC20(_token).transfer(_recipient, _amount);
    }
}
