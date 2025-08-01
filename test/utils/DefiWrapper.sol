// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ILidoLocator} from "lido-core/contracts/common/interfaces/ILidoLocator.sol";
import {ILido} from "src/interfaces/ILido.sol";
import {ILazyOracle} from "src/interfaces/ILazyOracle.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub as IVaultHubIntact} from "src/interfaces/IVaultHub.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";

import {Wrapper} from "src/Wrapper.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {Escrow} from "src/Escrow.sol";
import {ExampleStrategy, LenderMock} from "src/ExampleStrategy.sol";

interface IHashConsensus {
    function updateInitialEpoch(uint256 initialEpoch) external;
}

interface IACL {
    function grantPermission(address _entity, address _app, bytes32 _role) external;
    function grantRole(bytes32 role, address account) external;
    function createPermission(address _entity, address _app, bytes32 _role, address _manager) external;
    function setPermissionManager(address _newManager, address _app, bytes32 _role) external;
}

interface IVaultHub is IVaultHubIntact {
    function mock__setReportIsAlwaysFresh(bool _reportIsAlwaysFresh) external;
}

interface ICoreHarness {
    function dashboard() external view returns (IDashboard);
    function steth() external view returns (ILido);
}

contract DefiWrapper is Test {
    Wrapper public wrapper;
    WithdrawalQueue public withdrawalQueue;
    Escrow public escrow;
    ExampleStrategy public strategy;

    uint256 public constant STRATEGY_LOOPS = 2;

    constructor(address coreHarnessAddress) {
        ICoreHarness core = ICoreHarness(coreHarnessAddress);

        wrapper = new Wrapper{value: 0 wei}(
            address(core.dashboard()),
            address(0), // placeholder for escrow
            "Staked ETH Vault Wrapper",
            "stvETH"
        );

        withdrawalQueue = new WithdrawalQueue(wrapper);

        wrapper.setWithdrawalQueue(address(withdrawalQueue));

        strategy = new ExampleStrategy(address(core.steth()), address(wrapper), STRATEGY_LOOPS);

        escrow = new Escrow(address(wrapper), address(strategy), address(core.steth()));
        wrapper.setEscrowAddress(address(escrow));

        // Fund the LenderMock contract with ETH so it can lend
        vm.deal(address(strategy.LENDER_MOCK()), 1234 ether);
    }
}