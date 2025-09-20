// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {MockBoringVault} from "./MockBoringVault.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";

import {console} from "forge-std/console.sol";

contract MockBoringOnChainQueue is IBoringOnChainQueue {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    MockBoringVault public immutable vault;

    EnumerableSet.Bytes32Set private _withdrawRequests;

    mapping(address => WithdrawAsset) internal _withdrawAssets;

    uint96 public nonce;

    event OnChainWithdrawSolved(bytes32 indexed requestId, address indexed user, uint256 timestamp);

    error BoringOnChainQueue__Keccak256Collision();
    error BoringOnChainQueue__SolveAssetMismatch();
    error BoringOnChainQueue__NotMatured();
    error BoringOnChainQueue__DeadlinePassed();
    error BoringOnChainQueue__RequestNotFound();

    event OnChainWithdrawRequested(
        bytes32 indexed requestId,
        address indexed user,
        address indexed assetOut,
        uint96 nonce,
        uint128 amountOfShares,
        uint128 amountOfAssets,
        uint40 creationTime,
        uint24 secondsToMaturity,
        uint24 secondsToDeadline
    );

    event WithdrawAssetUpdated(
        address indexed assetOut,
        uint24 secondsToMaturity,
        uint24 minimumSecondsToDeadline,
        uint16 minDiscount,
        uint16 maxDiscount,
        uint96 minimumShares
    );

    constructor(address _vault) {
        vault = MockBoringVault(payable(_vault));
    }

    function previewAssetsOut(address assetOut, uint128 amountOfShares, uint16 discount)
    public
    view
    returns (uint128 amountOfAssets128)
    {
        uint256 price = ERC20(assetOut).totalSupply() / vault.totalSupply();

        console.log("MockBoringOnChainQueue price", price);
        console.log("MockBoringOnChainQueue ERC20(assetOut).totalSupply()", ERC20(assetOut).totalSupply());
        console.log("MockBoringOnChainQueue vault.totalSupply()", vault.totalSupply());
        console.log("MockBoringOnChainQueue amountOfShares", amountOfShares);


        price = Math.mulDiv(price, 1e4 - discount, 1e4);
        uint256 amountOfAssets = Math.mulDiv(amountOfShares, price * 1e14, 1e18);
        amountOfAssets128 = uint128(amountOfAssets);
    }

    function withdrawAssets(address _assetOut) external view returns(WithdrawAsset memory ) {
        return _withdrawAssets[_assetOut];
    }

    function updateWithdrawAsset(
        address assetOut,
        uint24 secondsToMaturity,
        uint24 minimumSecondsToDeadline,
        uint16 minDiscount,
        uint16 maxDiscount,
        uint96 minimumShares
    ) external {

        _withdrawAssets[assetOut] = WithdrawAsset({
            allowWithdraws: true,
            secondsToMaturity: secondsToMaturity,
            minimumSecondsToDeadline: minimumSecondsToDeadline,
            minDiscount: minDiscount,
            maxDiscount: maxDiscount,
            minimumShares: minimumShares,
            withdrawCapacity: type(uint256).max
        });

        emit WithdrawAssetUpdated(
            assetOut, secondsToMaturity, minimumSecondsToDeadline, minDiscount, maxDiscount, minimumShares
        );
    }

    function requestOnChainWithdraw(address assetOut, uint128 amountOfShares, uint16 discount, uint24 secondsToDeadline)
    external
    virtual
    returns (bytes32 requestId)
    {
        WithdrawAsset memory withdrawAsset = _withdrawAssets[assetOut];

        vault.transferFrom(msg.sender, address(this), amountOfShares);

        (requestId,) = _queueOnChainWithdraw(
            msg.sender, assetOut, amountOfShares, discount, withdrawAsset.secondsToMaturity, secondsToDeadline
        );
    }

    function _queueOnChainWithdraw(
        address user,
        address assetOut,
        uint128 amountOfShares,
        uint16 discount,
        uint24 secondsToMaturity,
        uint24 secondsToDeadline
    ) internal virtual returns (bytes32 requestId, OnChainWithdraw memory req) {
        // Create new request.
        uint96 requestNonce;
        // See nonce definition for unchecked safety.
        unchecked {
        // Set request nonce as current nonce, then increment nonce.
            requestNonce = nonce++;
        }

        uint128 amountOfAssets128 = previewAssetsOut(assetOut, amountOfShares, discount);

        uint40 timeNow = uint40(block.timestamp); // Safe to cast to uint40 as it won't overflow for 10s of thousands of years
        req = OnChainWithdraw({
            nonce: requestNonce,
            user: user,
            assetOut: assetOut,
            amountOfShares: amountOfShares,
            amountOfAssets: amountOfAssets128,
            creationTime: timeNow,
            secondsToMaturity: secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });

        requestId = keccak256(abi.encode(req));

        bool addedToSet = _withdrawRequests.add(requestId);

        if (!addedToSet) revert BoringOnChainQueue__Keccak256Collision();

        emit OnChainWithdrawRequested(
            requestId,
            user,
            assetOut,
            requestNonce,
            amountOfShares,
            amountOfAssets128,
            timeNow,
            secondsToMaturity,
            secondsToDeadline
        );
    }

    function solveOnChainWithdraws(OnChainWithdraw[] calldata requests, bytes calldata solveData, address solver)
    external
    {

        ERC20 solveAsset = ERC20(requests[0].assetOut);
        uint256 requiredAssets;
        uint256 totalShares;
        uint256 requestsLength = requests.length;
        for (uint256 i = 0; i < requestsLength; ++i) {
            if (address(solveAsset) != requests[i].assetOut) revert BoringOnChainQueue__SolveAssetMismatch();
            uint256 maturity = requests[i].creationTime + requests[i].secondsToMaturity;
            if (block.timestamp < maturity) revert BoringOnChainQueue__NotMatured();
            uint256 deadline = maturity + requests[i].secondsToDeadline;
            if (block.timestamp > deadline) revert BoringOnChainQueue__DeadlinePassed();
            requiredAssets += requests[i].amountOfAssets;
            totalShares += requests[i].amountOfShares;
            bytes32 requestId = _dequeueOnChainWithdraw(requests[i]);
            emit OnChainWithdrawSolved(requestId, requests[i].user, block.timestamp);
        }

        // Transfer shares to solver.
        vault.transfer(solver, totalShares);

        for (uint256 i = 0; i < requestsLength; ++i) {
            solveAsset.transferFrom(solver, requests[i].user, requests[i].amountOfAssets);
        }
    }

    function _dequeueOnChainWithdraw(OnChainWithdraw memory request) internal virtual returns (bytes32 requestId) {
        // Remove request from queue.
        requestId = keccak256(abi.encode(request));
        bool removedFromSet = _withdrawRequests.remove(requestId);
        if (!removedFromSet) revert BoringOnChainQueue__RequestNotFound();
    }

    function setWithdrawCapacity(address assetOut, uint256 withdrawCapacity) external {}
    function accountant() external view returns (address) {}
    function authority() external view returns (address){}
    function boringVault() external view returns (address){}
    function cancelOnChainWithdraw(OnChainWithdraw memory request) external returns (bytes32 requestId){}
    function getRequestIds() external view returns (bytes32[] memory){}
    function owner() external view returns (address){}
    function replaceOnChainWithdraw(OnChainWithdraw memory oldRequest, uint16 discount, uint24 secondsToDeadline) external returns (bytes32 oldRequestId, bytes32 newRequestId) {}
}