// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import { Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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

    function test_revertOnNotProposer() public {
        vm.startPrank(stranger);
        ProposalUpgradable.WrapperUpgradePayload memory payload = ProposalUpgradable.WrapperUpgradePayload({
            newImplementation: proposalUpgradableImplV2,
            newWqImplementation: address(wqImplementationV2),
            upgradeData: bytes("")
        });

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, proposalUpgradableProxy.UPGRADE_PROPOSER()));
        proposalUpgradableProxy.proposeUpgrade(payload);
        vm.stopPrank();
    }


    function test_canProposeUpgrade() public {
       ProposalUpgradable.ProposalUpgradableStorage memory currentProposal = proposalUpgradableProxy.getCurrentUpgradeProposal();

       assertEq(currentProposal.proposalHash, bytes32(0));
       assertEq(currentProposal.confirmationTimestamp, 0);


        ProposalUpgradable.WrapperUpgradePayload memory payload = ProposalUpgradable.WrapperUpgradePayload({
            newImplementation: proposalUpgradableImplV2,
            newWqImplementation: address(wqImplementationV2),
            upgradeData: bytes("")
        });

        bytes32 expectedHash = keccak256(abi.encode(payload));

        
        vm.expectEmit();
        emit ProposalUpgradable.WrapperUpgradeProposed(payload.newImplementation, payload.newWqImplementation,expectedHash);
        
        vm.prank(proposer);
        bytes32 proposalId = proposalUpgradableProxy.proposeUpgrade(payload);
        
        assertEq(proposalId, expectedHash);


        currentProposal = proposalUpgradableProxy.getCurrentUpgradeProposal();
        assertEq(currentProposal.proposalHash, expectedHash);
        assertEq(currentProposal.confirmationTimestamp, 0);
    }

    function test_canCancelProposal() public {
        ProposalUpgradable.WrapperUpgradePayload memory payload = ProposalUpgradable.WrapperUpgradePayload({
            newImplementation: proposalUpgradableImplV2,
            newWqImplementation: address(wqImplementationV2),
            upgradeData: bytes("")
        });

        bytes32 expectedHash = keccak256(abi.encode(payload));

        vm.prank(proposer);
        bytes32 proposalId = proposalUpgradableProxy.proposeUpgrade(payload);
        
        ProposalUpgradable.ProposalUpgradableStorage memory currentProposal = proposalUpgradableProxy.getCurrentUpgradeProposal();
        assertEq(currentProposal.proposalHash, expectedHash);
        assertEq(currentProposal.confirmationTimestamp, 0);


        vm.expectEmit();
        emit ProposalUpgradable.WrapperUpgradeCancelled(expectedHash);
        vm.prank(proposer);
        proposalUpgradableProxy.cancelUpgradeProposal();


        currentProposal = proposalUpgradableProxy.getCurrentUpgradeProposal();
        assertEq(currentProposal.proposalHash, bytes32(0));
        assertEq(currentProposal.confirmationTimestamp, 0);
    }

    function test_canConfirmProposal() public {
        ProposalUpgradable.WrapperUpgradePayload memory payload = ProposalUpgradable.WrapperUpgradePayload({
            newImplementation: proposalUpgradableImplV2,
            newWqImplementation: address(wqImplementationV2),
            upgradeData: bytes("")
        });

        bytes32 expectedHash = keccak256(abi.encode(payload));

        vm.prank(proposer);
        bytes32 proposalId = proposalUpgradableProxy.proposeUpgrade(payload);
        
        ProposalUpgradable.ProposalUpgradableStorage memory currentProposal = proposalUpgradableProxy.getCurrentUpgradeProposal();
        assertEq(currentProposal.proposalHash, expectedHash);
        assertEq(currentProposal.confirmationTimestamp, 0);

        
        vm.expectEmit();
        emit ProposalUpgradable.WrapperUpgradeConfirmed(expectedHash, uint64(block.timestamp) + proposalUpgradableProxy.UPGRADE_DELAY());
        vm.prank(conformer);  
        proposalUpgradableProxy.confirmUpgrade(payload);

        currentProposal = proposalUpgradableProxy.getCurrentUpgradeProposal();
        assertEq(currentProposal.proposalHash, expectedHash);
        assertEq(currentProposal.confirmationTimestamp, uint64(block.timestamp));
    }

    function test_canEnactProposal() public {
        ProposalUpgradable.WrapperUpgradePayload memory payload = ProposalUpgradable.WrapperUpgradePayload({
            newImplementation: proposalUpgradableImplV2,
            newWqImplementation: address(wqImplementationV2),
            upgradeData: bytes("")
        });

        bytes32 expectedHash = keccak256(abi.encode(payload));

        vm.prank(proposer);
        bytes32 proposalId = proposalUpgradableProxy.proposeUpgrade(payload);
        vm.prank(conformer);
        proposalUpgradableProxy.confirmUpgrade(payload);


        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ProposalUpgradable.TooEarlyToEnact.selector));
        proposalUpgradableProxy.enactUpgrade(payload);
      


        vm.warp(block.timestamp + proposalUpgradableProxy.UPGRADE_DELAY()+1);
        
        vm.expectEmit();
        emit ProposalUpgradable.WrapperUpgradeEnacted( payload.newImplementation, payload.newWqImplementation,expectedHash);
        vm.prank(stranger);
        proposalUpgradableProxy.enactUpgrade(payload);

        ProposalUpgradable.ProposalUpgradableStorage memory currentProposal = proposalUpgradableProxy.getCurrentUpgradeProposal();
        assertEq(currentProposal.proposalHash, bytes32(0));
        assertEq(currentProposal.confirmationTimestamp, 0);
    }
}