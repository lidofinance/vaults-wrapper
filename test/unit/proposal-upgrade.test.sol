// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import { Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ProposalUpgradableHarness} from "test/utils/ProposalUpgradableHarness.sol";
import {MockUpgradableWq} from "test/mocks/MockUpgradableWq.sol";

import {ProposalUpgradable} from "src/ProposalUpgradable.sol";



contract ProposalUpgradableTest is Test {

    // Wrapper implementations and proxy
    address public proposalUpgradableImpl;
    address public proposalUpgradableImplV2;
    ProposalUpgradableHarness public proposalUpgradableProxy;
   
    // WQ implementations and proxy
    address public wqImplementation;
    address public wqImplementationV2;
    MockUpgradableWq public wqProxy;

    address public admin;
    address public proposer;
    address public conformer;
    address public stranger;

    function setUp() public {

        admin = address(0xABCD);
        proposer = address(0xBEEF);
        conformer = address(0xCAFE);
        stranger = address(0xDEAD);

      

        vm.label(admin, "Admin");
        vm.label(proposer, "Proposer");
        vm.label(conformer, "Conformer");
        vm.label(stranger, "Stranger");


        proposalUpgradableImpl = address(new ProposalUpgradableHarness());
        proposalUpgradableImplV2 = address(new ProposalUpgradableHarness());


        proposalUpgradableProxy = ProposalUpgradableHarness(address(new ERC1967Proxy(
          proposalUpgradableImpl,
          new bytes(0)
        )));

        wqImplementation = address(new MockUpgradableWq(address(proposalUpgradableProxy)));
        wqImplementationV2 = address(new MockUpgradableWq(address(proposalUpgradableProxy)));

        wqProxy = MockUpgradableWq(address(new ERC1967Proxy(
          wqImplementation,
          new bytes(0)
        )));

        proposalUpgradableProxy.initialize(admin, proposer, conformer, address(wqProxy));

    }

    function test_upgradeHappyPath() public {
        vm.startPrank(proposer);
        ProposalUpgradable.WrapperUpgradePayload memory payload = ProposalUpgradable.WrapperUpgradePayload({
            newImplementation: proposalUpgradableImplV2,
            newWqImplementation: address(wqImplementationV2),
            upgradeData: abi.encodeWithSignature("initializeUpgrade()")
        });

        bytes32 proposalId = proposalUpgradableProxy.proposeUpgrade(payload);

        vm.stopPrank();

        vm.startPrank(conformer);
        proposalUpgradableProxy.setCanUpgrade(true);
        proposalUpgradableProxy.confirmUpgrade(payload);
        vm.warp(block.timestamp + proposalUpgradableProxy.UPGRADE_DELAY()+1);
        proposalUpgradableProxy.enactUpgrade(payload);
        vm.stopPrank();

        
        
        assertEq(proposalUpgradableProxy.getImplementation(), proposalUpgradableImplV2);
        assertEq(wqProxy.getImplementation(), wqImplementationV2);

    }
}