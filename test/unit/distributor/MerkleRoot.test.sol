// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SetupDistributor} from "./SetupDistributor.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";
import {Distributor} from "src/Distributor.sol";

contract MerkleRootTest is Test, SetupDistributor {
    function setUp() public override {
        super.setUp();
    }

    // ==================== Error Cases ====================

    function test_SetMerkleRoot_RevertsIfNotManager() public {
        bytes32 newRoot = keccak256("testRoot");
        string memory newCid = "QmTestCID";

        bytes32 managerRole = distributor.MANAGER_ROLE();

        vm.prank(userAlice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userAlice, managerRole)
        );
        distributor.setMerkleRoot(newRoot, newCid);
    }

    function test_SetMerkleRoot_RevertsWhenNoChanges() public {
        bytes32 initialRoot = keccak256("root");
        string memory initialCid = "QmCID";

        vm.startPrank(manager);
        distributor.setMerkleRoot(initialRoot, initialCid);

        vm.expectRevert(Distributor.AlreadyProcessed.selector);
        distributor.setMerkleRoot(initialRoot, initialCid);
        vm.stopPrank();
    }

    function test_SetMerkleRoot_AllowsPartialUpdates() public {
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");
        string memory cid1 = "QmCid1";
        string memory cid2 = "QmCid2";

        vm.startPrank(manager);
        distributor.setMerkleRoot(root1, cid1);

        // Same root, new cid
        distributor.setMerkleRoot(root1, cid2);

        // Same cid, new root
        distributor.setMerkleRoot(root2, cid2);
        vm.stopPrank();
    }

    // ==================== Successful Merkle Root Setting ====================

    function test_SetMerkleRoot_SuccessfullySetsRoot() public {
        bytes32 newRoot = keccak256("testRoot");
        string memory newCid = "QmTestCID";

        vm.prank(manager);
        distributor.setMerkleRoot(newRoot, newCid);

        assertEq(distributor.root(), newRoot);
        assertEq(distributor.cid(), newCid);
    }

    function test_SetMerkleRoot_UpdatesLastProcessedBlock() public {
        bytes32 newRoot = keccak256("testRoot");
        string memory newCid = "QmTestCID";

        uint256 blockBefore = distributor.lastProcessedBlock();

        vm.roll(block.number + 100);

        vm.prank(manager);
        distributor.setMerkleRoot(newRoot, newCid);

        assertEq(distributor.lastProcessedBlock(), block.number);
        assertTrue(distributor.lastProcessedBlock() > blockBefore);
    }

    function test_SetMerkleRoot_EmitsEvent() public {
        bytes32 oldRoot = distributor.root();
        string memory oldCid = distributor.cid();
        uint256 oldBlock = distributor.lastProcessedBlock();

        bytes32 newRoot = keccak256("testRoot");
        string memory newCid = "QmTestCID";

        vm.expectEmit(true, true, false, true);
        emit MerkleRootUpdated(oldRoot, newRoot, oldCid, newCid, oldBlock, block.number);

        vm.prank(manager);
        distributor.setMerkleRoot(newRoot, newCid);
    }

    function test_SetMerkleRoot_OwnerCanSetRootAfterGrant() public {
        bytes32 newRoot = keccak256("testRoot");
        string memory newCid = "QmTestCID";

        vm.startPrank(owner);
        distributor.grantRole(distributor.MANAGER_ROLE(), owner);
        distributor.setMerkleRoot(newRoot, newCid);
        vm.stopPrank();

        assertEq(distributor.root(), newRoot);
    }
}

