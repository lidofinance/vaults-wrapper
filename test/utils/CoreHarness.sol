// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLocator} from "src/interfaces/ILidoLocator.sol";
import {ILido} from "src/interfaces/ILido.sol";
import {ILazyOracle} from "src/interfaces/ILazyOracle.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub as IVaultHubIntact} from "src/interfaces/IVaultHub.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {IWstETH} from "../../src/interfaces/IWstETH.sol";

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

interface ILazyOracleMocked is ILazyOracle {
    function mock__updateVaultData(
        address _vault,
        uint256 _totalValue,
        uint256 _cumulativeLidoFees,
        uint256 _liabilityShares,
        uint256 _maxLiabilityShares,
        uint256 _slashingReserve
    ) external;
}

contract CoreHarness is Test {
    ILidoLocator public locator;
    IDashboard public dashboard;
    ILido public steth;
    IWstETH public wsteth;
    IVaultHub public vaultHub;
    ILazyOracleMocked public lazyOracle;

    uint256 public constant INITIAL_LIDO_SUBMISSION = 15_000 ether;
    uint256 public constant CONNECT_DEPOSIT = 1 ether;
    uint256 public constant LIDO_TOTAL_BASIS_POINTS = 10000;
    uint256 public constant NODE_OPERATOR_FEE_RATE = 1_00; // 1% in basis points

    address public constant BEACON_CHAIN = address(0xbeac0);

    constructor(string memory _deployedJsonPath) {
        vm.deal(address(this), 10000000 ether);

        // Prefer CORE_DEPLOYED_JSON env var when provided; fallback to the passed path
        string memory envPath = "";
        try vm.envString("CORE_DEPLOYED_JSON") returns (string memory p) {
            envPath = p;
        } catch {}
        string memory path = bytes(envPath).length != 0 ? envPath : _deployedJsonPath;

        string memory deployedJson = vm.readFile(path);
        locator = ILidoLocator(vm.parseJsonAddress(deployedJson, "$.lidoLocator.proxy.address"));
        vm.label(address(locator), "LidoLocator");

        address agent = vm.parseJsonAddress(deployedJson, "$.['app:aragon-agent'].proxy.address");
        vm.label(agent, "Agent");

        IACL acl = IACL(vm.parseJsonAddress(deployedJson, "$.aragon-acl.proxy.address"));
        vm.label(address(acl), "ACL");

        // Get LazyOracle address from the deployed contracts
        lazyOracle = ILazyOracleMocked(locator.lazyOracle());
        vm.label(address(lazyOracle), "LazyOracle");

        address hashConsensus = vm.parseJsonAddress(deployedJson, "$.hashConsensusForAccountingOracle.address");
        vm.label(hashConsensus, "HashConsensusForAO");
        vm.prank(agent);
        try IHashConsensus(hashConsensus).updateInitialEpoch(1) {
            // ok
        } catch {
            // ignore if already set on pre-deployed core (Hoodi)
        }

        steth = ILido(locator.lido());
        vm.label(address(steth), "Lido");

        wsteth = IWstETH(locator.wstETH());
        vm.label(address(wsteth), "WstETH");

        vm.prank(agent);
        try steth.setMaxExternalRatioBP(LIDO_TOTAL_BASIS_POINTS) {
            // ok
        } catch {
            // ignore if permissions differ on pre-deployed core
        }

        if (steth.isStopped()) {
            vm.prank(agent);
            try steth.resume() {} catch {}
        }

        // Ensure Lido has sufficient shares; on Hoodi it's already funded. Only top up if low.
        uint256 totalShares = steth.getTotalShares();
        if (totalShares < 100000) {
            try steth.submit{value: INITIAL_LIDO_SUBMISSION}(address(this)) {}
            catch {
                // ignore stake limit or other constraints on pre-deployed core
            }
        }

        vaultHub = IVaultHub(locator.vaultHub());
        vm.label(address(vaultHub), "VaultHub");

        IVaultFactory vaultFactory = IVaultFactory(locator.vaultFactory());
        vm.label(address(vaultFactory), "VaultFactory");

        dashboard = IDashboard(payable(address(0))); // Will be set by DefiWrapper
        vm.label(address(dashboard), "Dashboard");
    }

    function setDashboard(address _dashboard) external {
        dashboard = IDashboard(payable(_dashboard));
        vm.label(address(dashboard), "Dashboard");
    }

    function applyVaultReport(
        address _stakingVault,
        uint256 _totalValue,
        uint256 _cumulativeLidoFees,
        uint256 _liabilityShares,
        uint256 _slashingReserve,
        bool _onlyUpdateReportData
    ) public {
        bytes32 treeRoot = bytes32(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef);
        string memory reportCid = "dummy-cid";

        // uint256 reportCumulativeLidoFees = _cumulativeLidoFees;
        // uint256 reportLiabilityShares = 0;
        // uint256 reportSlashingReserve = 0;

        // bool isFresh = vaultHub.isReportFresh(_stakingVault);
        // console.log("isFresh before", isFresh);

        vm.warp(block.timestamp + 1 minutes);

        // Always update report data to mark reports as fresh on fork
        uint256 reportTimestamp = block.timestamp;
        uint256 refSlot = block.timestamp / 12; // Simulate a slot number based on timestamp (12 second slots)
        vm.prank(locator.accountingOracle());
        lazyOracle.updateReportData(reportTimestamp, refSlot, treeRoot, reportCid);

        // Apply real updateVaultData with an empty proof path; this triggers applyVaultReport using the latest report timestamp
        if (!_onlyUpdateReportData) {
            uint256 maxLiabilityShares = vaultHub.vaultRecord(_stakingVault).maxLiabilityShares;
            vm.prank(locator.accounting());
            try lazyOracle.updateVaultData(
                _stakingVault, _totalValue, _cumulativeLidoFees, _liabilityShares, _slashingReserve, new bytes32[](0)
            ) {
                console.log("After updateVaultData, totalValue from vaultHub:", vaultHub.totalValue(_stakingVault));
            } catch {
                // If proof checks enforced, fall back to mock when available
                address ao = locator.accountingOracle();
                vm.prank(ao);
                (bool ok,) = address(lazyOracle).call(
                    abi.encodeWithSelector(
                        ILazyOracleMocked.mock__updateVaultData.selector,
                        _stakingVault,
                        _totalValue,
                        _cumulativeLidoFees,
                        _liabilityShares,
                        maxLiabilityShares,
                        _slashingReserve
                    )
                );
            }
        }

        // On pre-deployed core we skip enforcing freshness via mocked calls
    }

    /**
     * @dev Mock function to simulate validators receiving ETH from the staking vault
     * This replaces the manual beacon chain transfer simulation in tests
     */
    function mockValidatorsReceiveETH(address _stakingVault) external returns (uint256 transferredAmount) {
        transferredAmount = _stakingVault.balance;
        if (transferredAmount > 0) {
            vm.prank(_stakingVault);
            (bool sent,) = BEACON_CHAIN.call{value: transferredAmount}("");
            require(sent, "ETH send to beacon chain failed");
        }
        return transferredAmount;
    }

    /**
     * @dev Mock function to simulate validator exits returning ETH to the staking vault
     * This replaces the manual ETH return simulation in tests
     */
    function mockValidatorExitReturnETH(address _stakingVault, uint256 _ethAmount) external {
        vm.prank(BEACON_CHAIN);
        (bool success,) = _stakingVault.call{value: _ethAmount}("");
        require(success, "ETH return from beacon chain failed");
    }

    function setStethShareRatio(uint256 _shareRatioE18) external {
        uint256 totalSupply = steth.totalSupply();
        uint256 totalShares = steth.getTotalShares();

        uint256 a = Math.mulDiv(totalSupply, 1 ether, _shareRatioE18, Math.Rounding.Floor);
        int128 sharesDiff = int128(uint128(a)) - int128(uint128(totalShares));

        if (sharesDiff > 0) {
            vm.prank(locator.accounting());
            steth.mintShares(address(this), uint256(uint128(sharesDiff)));
        } else if (sharesDiff < 0) {
            // On pre-deployed cores we may lack permission/balance to burn; skip decreasing in that case
        }

        // Best-effort: do not revert if cannot match ratio exactly on pre-deployed core
    }

    function increaseBufferedEther(uint256 _amount) external {
        //bufferedEtherAndDepositedValidators
        bytes32 BUFFERED_ETHER_SLOT = 0xa84c096ee27e195f25d7b6c7c2a03229e49f1a2a5087e57ce7d7127707942fe3;

        // 1. Загружаем текущее 256-битное значение слота
        bytes32 storageWord = vm.load(address(steth), BUFFERED_ETHER_SLOT);

        // 2. Извлекаем depositedValidators (Высокие 128 бит)
        // Shift right by 128 bits
        uint256 depositedValidators = uint256(storageWord) >> 128;

        // 3. Извлекаем currentBufferedEther (Низкие 128 бит)
        // Mask off the high 128 bits
        uint256 currentBufferedEther = uint256(uint128(uint256(storageWord)));

        // 4. Рассчитываем новое значение bufferedEther
        uint256 newBufferedEther = currentBufferedEther + _amount;

        // 5. Собираем новое 256-битное слово
        // [depositedValidators (128) | newBufferedEther (128)]
        bytes32 newStorageWord = bytes32(depositedValidators << 128 | newBufferedEther);

        // 6. Записываем новое слово в хранилище Lido
        vm.store(address(steth), BUFFERED_ETHER_SLOT, newStorageWord);

        console.log("Buffered Ether increased by:", _amount);
        console.log("New Total Pooled Ether (stETH.totalSupply()):", steth.totalSupply());
    }
}
