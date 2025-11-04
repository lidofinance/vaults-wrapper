// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {SetupDistributor} from "./SetupDistributor.sol";
import {Distributor} from "src/Distributor.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                userAlice,
                managerRole
            )
        );
        distributor.setMerkleRoot(newRoot, newCid);
    }

    function test_SetMerkleRoot_RevertsOnSameRoot() public {
        bytes32 newRoot = keccak256("testRoot");
        string memory cid1 = "QmTestCID1";

        vm.prank(manager);
        distributor.setMerkleRoot(newRoot, cid1);

        // Try to set the same root with different CID
        string memory cid2 = "QmTestCID2";

        vm.prank(manager);
        vm.expectRevert(Distributor.AlreadyProcessed.selector);
        distributor.setMerkleRoot(newRoot, cid2);
    }

    function test_SetMerkleRoot_RevertsOnSameCid() public {
        bytes32 root1 = keccak256("root1");
        string memory sameCid = "QmTestCID";

        vm.prank(manager);
        distributor.setMerkleRoot(root1, sameCid);

        // Try to set different root with same CID
        bytes32 root2 = keccak256("root2");

        vm.prank(manager);
        vm.expectRevert(Distributor.AlreadyProcessed.selector);
        distributor.setMerkleRoot(root2, sameCid);
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



