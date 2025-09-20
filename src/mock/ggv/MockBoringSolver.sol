// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {MockBoringVault} from "./MockBoringVault.sol";
import {IBoringSolver} from "src/interfaces/ggv/IBoringSolver.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {MockBoringOnChainQueue} from "./MockBoringOnChainQueue.sol";

contract MockBoringSolver is IBoringSolver {

    MockBoringVault public immutable vault;
    MockBoringOnChainQueue public immutable queue;

    constructor(address _vault, address _queue) {
        vault = MockBoringVault(payable(_vault));
        queue = MockBoringOnChainQueue(_queue);
    }

    function boringSolve(
        address initiator,
        address boringVault,
        address solveAsset,
        uint256 totalShares,
        uint256 requiredAssets,
        bytes calldata solveData
    ) external {

    }

    function boringRedeemSolve(
        IBoringOnChainQueue.OnChainWithdraw[] calldata requests,
        address teller,
        bool coverDeficit
    ) external {
        bytes memory solveData = abi.encode(block.timestamp);

        queue.solveOnChainWithdraws(requests, solveData, address(this));
    }
    
}