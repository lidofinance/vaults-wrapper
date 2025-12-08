// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {StvStETHPool} from "../StvStETHPool.sol";
import {WithdrawalQueue} from "../WithdrawalQueue.sol";
import {IStrategyCallForwarder} from "../interfaces/IStrategyCallForwarder.sol";

import {IDepositQueue} from "../interfaces/streth/IDepositQueue.sol";
import {IQueue} from "../interfaces/streth/IQueue.sol";
import {IRedeemQueue} from "../interfaces/streth/IRedeemQueue.sol";

import {IOracle} from "../interfaces/streth/IOracle.sol";
import {IShareManager} from "../interfaces/streth/IShareManager.sol";
import {IVault} from "../interfaces/streth/IVault.sol";

import {StrategyCallForwarderRegistry} from "../strategy/StrategyCallForwarderRegistry.sol";
import {FeaturePausable} from "../utils/FeaturePausable.sol";

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IWstETH} from "../interfaces/core/IWstETH.sol";

contract StrETHStrategy is
    IStrategy,
    AccessControlEnumerableUpgradeable,
    FeaturePausable,
    StrategyCallForwarderRegistry
{
    using SafeCast for uint256;

    StvStETHPool private immutable POOL_;
    IWstETH public immutable WSTETH;

    IOracle public immutable STRETH_ORACLE;
    IShareManager public immutable STRETH_SHARE_MANAGER;
    IDepositQueue public immutable WSTETH_DEPOSIT_QUEUE;
    IRedeemQueue public immutable WSTETH_REDEEM_QUEUE;

    // ACL
    bytes32 public constant SUPPLY_FEATURE = keccak256("SUPPLY_FEATURE");
    bytes32 public constant SUPPLY_PAUSE_ROLE = keccak256("SUPPLY_PAUSE_ROLE");
    bytes32 public constant SUPPLY_RESUME_ROLE = keccak256("SUPPLY_RESUME_ROLE");

    event StrETHDeposited(
        address indexed recipient, uint256 wstethAmount, address indexed referralAddress, bytes params
    );
    event StrETHWithdrawalRequested(address indexed recipient, bytes32 requestId, uint256 strETH, bytes params);

    error ZeroArgument(string name);
    error InvalidQueue(string name);
    error SuspiciousReport();
    error InvalidSender();
    error InvalidWstethAmount();
    error NothingToExit();
    error NotImplemented();

    constructor(
        bytes32 _strategyId,
        address _strategyCallForwarderImpl,
        address _pool,
        address _strETH,
        address _depositQueue,
        address _redeemQueue
    ) StrategyCallForwarderRegistry(_strategyId, _strategyCallForwarderImpl) {
        POOL_ = StvStETHPool(payable(_pool));
        WSTETH = IWstETH(POOL_.WSTETH());

        IVault vault = IVault(_strETH);
        if (
            !vault.hasQueue(_depositQueue) || !vault.isDepositQueue(_depositQueue)
                || IQueue(_depositQueue).asset() != address(WSTETH)
        ) {
            revert InvalidQueue("_depositQueue");
        }
        if (
            !vault.hasQueue(_redeemQueue) || vault.isDepositQueue(_depositQueue)
                || IQueue(_redeemQueue).asset() != address(WSTETH)
        ) {
            revert InvalidQueue("_redeemQueue");
        }

        STRETH_ORACLE = vault.oracle();
        STRETH_SHARE_MANAGER = vault.shareManager();
        WSTETH_DEPOSIT_QUEUE = IDepositQueue(_depositQueue);
        WSTETH_REDEEM_QUEUE = IRedeemQueue(_redeemQueue);

        _disableInitializers();
        _pauseFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Initialize the contract storage explicitly
     * @param _admin Admin address that can change every role
     * @param _supplyPauser Address that can pause supply (zero for none)
     * @dev Reverts if `_admin` equals to `address(0)`
     */
    function initialize(address _admin, address _supplyPauser) external initializer {
        if (_admin == address(0)) revert ZeroArgument("_admin");

        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        if (address(0) != _supplyPauser) {
            _grantRole(SUPPLY_PAUSE_ROLE, _supplyPauser);
        }
    }

    /**
     * @inheritdoc IStrategy
     */
    function POOL() external view returns (address) {
        return address(POOL_);
    }

    // =================================================================================
    // PAUSE / RESUME
    // =================================================================================

    /**
     * @notice Pause supply
     */
    function pauseSupply() external onlyRole(SUPPLY_PAUSE_ROLE) {
        _pauseFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Resume supply
     */
    function resumeSupply() external onlyRole(SUPPLY_RESUME_ROLE) {
        _resumeFeature(SUPPLY_FEATURE);
    }

    // =================================================================================
    // SUPPLY
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function supply(address _referral, uint256 _wstethToMint, bytes calldata _params)
        external
        payable
        returns (uint256 stv)
    {
        _checkFeatureNotPaused(SUPPLY_FEATURE);

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());

        if (msg.value > 0) {
            stv = POOL_.depositETH{value: msg.value}(address(callForwarder), _referral);
        }

        callForwarder.doCall(address(POOL_), abi.encodeWithSelector(POOL_.mintWsteth.selector, _wstethToMint));
        callForwarder.doCall(
            address(WSTETH),
            abi.encodeWithSelector(WSTETH.approve.selector, address(WSTETH_DEPOSIT_QUEUE), _wstethToMint)
        );

        bytes32[] memory merkleProof;
        if (_params.length > 0) {
            merkleProof = abi.decode(_params, (bytes32[]));
        }

        callForwarder.doCall(
            address(WSTETH_DEPOSIT_QUEUE),
            abi.encodeCall(IDepositQueue.deposit, (_wstethToMint.toUint224(), _referral, merkleProof))
        );

        emit StrategySupplied(_msgSender(), _referral, msg.value, stv, _wstethToMint, _params);
        emit StrETHDeposited(_msgSender(), _wstethToMint, _referral, _params);
    }

    // =================================================================================
    // REQUEST EXIT FROM STRATEGY
    // =================================================================================

    /**
     * @notice Previews the amount of wstETH that can be withdrawn by a given amount of strETH shares
     * @param _strETHShares The amount of strETH shares to preview the amount of wstETH for
     * @return wsteth The amount of wstETH that can be withdrawn
     */
    function previewWstethByStrETH(uint256 _strETHShares) public view returns (uint256 wsteth) {
        IOracle.DetailedReport memory report = STRETH_ORACLE.getReport(address(WSTETH));
        if (report.isSuspicious) {
            revert SuspiciousReport();
        }
        if (report.priceD18 == 0) {
            revert ZeroArgument("_priceD18");
        }
        return Math.mulDiv(_strETHShares, 1 ether, report.priceD18);
    }

    /**
     * @inheritdoc IStrategy
     */
    function requestExitByWsteth(uint256 _wsteth, bytes calldata _params) external returns (bytes32 requestId) {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());

        // Calculate how much wsteth we'll get from total strETH shares
        uint256 totalStrETH = STRETH_SHARE_MANAGER.sharesOf(address(callForwarder));
        uint256 totalWstethFromStrETH = previewWstethByStrETH(totalStrETH);
        if (totalWstethFromStrETH == 0) revert InvalidWstethAmount();
        if (_wsteth > totalWstethFromStrETH) revert NothingToExit();

        uint256 strETHShares = Math.mulDiv(totalStrETH, _wsteth, totalWstethFromStrETH, Math.Rounding.Ceil);
        // Withdrawal request from strETH
        callForwarder.doCall(address(WSTETH_REDEEM_QUEUE), abi.encodeCall(IRedeemQueue.redeem, (strETHShares)));

        requestId = bytes32(block.timestamp);

        emit StrategyExitRequested(_msgSender(), requestId, _wsteth, _params);
        emit StrETHWithdrawalRequested(_msgSender(), requestId, strETHShares, _params);
    }

    /**
     * @inheritdoc IStrategy
     */
    function finalizeRequestExit(bytes32 _requestId) external {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint256(_requestId).toUint32();
        bytes memory response = callForwarder.doCall(
            address(WSTETH_REDEEM_QUEUE), abi.encodeCall(IRedeemQueue.claim, (address(callForwarder), timestamps))
        );
        uint256 wsteth = abi.decode(response, (uint256));

        emit StrategyExitFinalized(_msgSender(), _requestId, wsteth);
    }

    // =================================================================================
    // HELPERS
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function mintedStethSharesOf(address _user) external view returns (uint256 mintedStethShares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        mintedStethShares = POOL_.mintedStethSharesOf(address(callForwarder));
    }

    /**
     * @inheritdoc IStrategy
     */
    function remainingMintingCapacitySharesOf(address _user, uint256 _ethToFund)
        external
        view
        returns (uint256 stethShares)
    {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        stethShares = POOL_.remainingMintingCapacitySharesOf(address(callForwarder), _ethToFund);
    }

    /**
     * @inheritdoc IStrategy
     */
    function wstethOf(address _user) external view returns (uint256 wsteth) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        wsteth = WSTETH.balanceOf(address(callForwarder));
    }

    /**
     * @inheritdoc IStrategy
     */
    function stvOf(address _user) external view returns (uint256 stv) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        stv = POOL_.balanceOf(address(callForwarder));
    }

    /**
     * @notice Returns the amount of strETH shares of a user
     * @param _user The user to get the strETH shares for
     * @return strETHShares The amount of strETH shares
     */
    function strETHOf(address _user) external view returns (uint256 strETHShares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        strETHShares = STRETH_SHARE_MANAGER.sharesOf(address(callForwarder));
    }

    // =================================================================================
    // REQUEST WITHDRAWAL FROM POOL
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function requestWithdrawalFromPool(address _recipient, uint256 _stvToWithdraw, uint256 _stethSharesToRebalance)
        external
        returns (uint256 requestId)
    {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());

        // request withdrawal from pool
        bytes memory withdrawalData = callForwarder.doCall(
            address(POOL_.WITHDRAWAL_QUEUE()),
            abi.encodeWithSelector(
                WithdrawalQueue.requestWithdrawal.selector, _recipient, _stvToWithdraw, _stethSharesToRebalance
            )
        );
        requestId = abi.decode(withdrawalData, (uint256));
    }

    /**
     * @notice Burns wstETH to reduce the user's minted stETH obligation
     * @param _wstethToBurn The amount of wstETH to burn
     */
    function burnWsteth(uint256 _wstethToBurn) external {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());
        callForwarder.doCall(
            address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, address(POOL_), _wstethToBurn)
        );
        callForwarder.doCall(address(POOL_), abi.encodeWithSelector(StvStETHPool.burnWsteth.selector, _wstethToBurn));
    }

    // =================================================================================
    // RECOVERY
    // =================================================================================

    /**
     * @notice Recovers ERC20 tokens from the call forwarder
     * @param _token The token to recover
     * @param _recipient The recipient of the tokens
     * @param _amount The amount of tokens to recover
     */
    function recoverERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());
        callForwarder.doCall(_token, abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _amount));
    }
}
