// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {SetupDistributor} from "./SetupDistributor.sol";
import {Distributor} from "src/Distributor.sol";
import {MerkleTree} from "test/utils/MerkleTree.sol";

contract ClaimingTest is Test, SetupDistributor {
    function setUp() public override {
        super.setUp();

        vm.startPrank(manager);
        distributor.addToken(address(token1));
        distributor.addToken(address(token2));
        vm.stopPrank();
    }

    // ==================== Error Cases ====================

    function test_Claim_RevertsIfRootNotSet() public {
        // Deploy new distributor without setting root
        Distributor newDistributor = new Distributor(owner);
        
        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(Distributor.RootNotSet.selector);
        newDistributor.claim(userAlice, address(token1), 100 ether, proof);
    }

    function test_Claim_RevertsOnInvalidProof() public {
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        
        bytes32 root = merkleTree.root();
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        // Use wrong proof
        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = keccak256("wrong");

        vm.prank(userAlice);
        vm.expectRevert(Distributor.InvalidProof.selector);
        distributor.claim(userAlice, address(token1), claimAmount, wrongProof);
    }

    function test_Claim_RevertsOnClaimableTooLow() public {
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        
        bytes32 root = merkleTree.root();
        bytes32[] memory proof = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        // First claim
        vm.prank(userAlice);
        distributor.claim(userAlice, address(token1), claimAmount, proof);

        // Try to claim again with same amount (no new rewards)
        vm.prank(userAlice);
        vm.expectRevert(Distributor.ClaimableTooLow.selector);
        distributor.claim(userAlice, address(token1), claimAmount, proof);
    }

    function test_Claim_RevertsOnWrongRecipient() public {
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        
        bytes32 root = merkleTree.root();
        bytes32[] memory proof = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        // Try to claim with wrong recipient
        vm.prank(userBob);
        vm.expectRevert(Distributor.InvalidProof.selector);
        distributor.claim(userBob, address(token1), claimAmount, proof);
    }

    function test_Claim_RevertsOnWrongToken() public {
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        
        bytes32 root = merkleTree.root();
        bytes32[] memory proof = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        // Try to claim with wrong token
        vm.prank(userAlice);
        vm.expectRevert(Distributor.InvalidProof.selector);
        distributor.claim(userAlice, address(token2), claimAmount, proof);
    }

    function test_Claim_RevertsOnWrongAmount() public {
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        
        bytes32 root = merkleTree.root();
        bytes32[] memory proof = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        // Try to claim with wrong amount
        vm.prank(userAlice);
        vm.expectRevert(Distributor.InvalidProof.selector);
        distributor.claim(userAlice, address(token1), 200 ether, proof);
    }

    // ==================== Basic Claiming Tests ====================

    function test_Claim_SuccessfulClaim() public {
        // Setup: Create merkle tree with one claim
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        
        bytes32 root = merkleTree.root();
        bytes32[] memory proof = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        uint256 balanceBefore = token1.balanceOf(userAlice);

        // Act: Claim
        vm.prank(userAlice);
        uint256 claimedAmount = distributor.claim(userAlice, address(token1), claimAmount, proof);

        // Assert
        assertEq(claimedAmount, claimAmount);
        assertEq(token1.balanceOf(userAlice), balanceBefore + claimAmount);
        assertEq(distributor.claimed(userAlice, address(token1)), claimAmount);
    }

    function test_Claim_EmitsClaimedEvent() public {
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        
        bytes32 root = merkleTree.root();
        bytes32[] memory proof = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        vm.expectEmit(true, true, false, true);
        emit Claimed(userAlice, address(token1), claimAmount);

        vm.prank(userAlice);
        distributor.claim(userAlice, address(token1), claimAmount, proof);
    }

    function test_Claim_AnyoneCanClaimOnBehalf() public {
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        
        bytes32 root = merkleTree.root();
        bytes32[] memory proof = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        uint256 balanceBefore = token1.balanceOf(userAlice);

        // userBob claims on behalf of userAlice
        vm.prank(userBob);
        uint256 claimedAmount = distributor.claim(userAlice, address(token1), claimAmount, proof);

        assertEq(claimedAmount, claimAmount);
        assertEq(token1.balanceOf(userAlice), balanceBefore + claimAmount);
    }

    function test_Claim_MultipleUsersCanClaim() public {
        // Setup three leaf tree
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), 100 ether));
        merkleTree.pushLeaf(_leafData(userBob, address(token1), 200 ether));
        merkleTree.pushLeaf(_leafData(userCharlie, address(token2), 300 ether));

        
        bytes32 root = merkleTree.root();
        
        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        assertEq(token1.balanceOf(userAlice), 0);
        assertEq(token1.balanceOf(userBob), 0);
        assertEq(token2.balanceOf(userCharlie), 0);

        // Alice claims 100 ether of token1
        vm.prank(userAlice);
        distributor.claim(userAlice, address(token1), 100 ether, merkleTree.getProof(0));
        assertEq(token1.balanceOf(userAlice), 100 ether);

        // Bob claims 200 ether of token1
        vm.prank(userBob);
        distributor.claim(userBob, address(token1), 200 ether, merkleTree.getProof(1));
        assertEq(token1.balanceOf(userBob), 200 ether);

        // Charlie claims 300 ether of token2
        vm.prank(userCharlie);
        distributor.claim(userCharlie, address(token2), 300 ether, merkleTree.getProof(2));
        assertEq(token2.balanceOf(userCharlie), 300 ether);
    }

    // ==================== Partial and Multiple Claims ====================

    function test_Claim_PartialClaim() public {
        // First claim with 50 ether
        uint256 amount1 = 50 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), amount1));
        
        bytes32 root1 = merkleTree.root();
        bytes32[] memory proof1 = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root1, "QmTest1");

        vm.prank(userAlice);
        uint256 claimed1 = distributor.claim(userAlice, address(token1), amount1, proof1);
        assertEq(claimed1, 50 ether);
        assertEq(distributor.claimed(userAlice, address(token1)), 50 ether);

        // Update root with higher amount (100 ether total)
        uint256 amount2 = 100 ether;
        merkleTree = new MerkleTree(); // Reset tree
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), amount2));
        
        bytes32 root2 = merkleTree.root();
        bytes32[] memory proof2 = merkleTree.getProof(0);
        
        vm.prank(manager);
        distributor.setMerkleRoot(root2, "QmTest2");

        // Second claim - should get difference (50 more)
        vm.prank(userAlice);
        uint256 claimed2 = distributor.claim(userAlice, address(token1), amount2, proof2);
        assertEq(claimed2, 50 ether);
        assertEq(distributor.claimed(userAlice, address(token1)), 100 ether);
        assertEq(token1.balanceOf(userAlice), 100 ether);
    }

    function test_Claim_MultipleDifferentTokens() public {
        // Setup claims for same user, different tokens
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), 100 ether));
        merkleTree.pushLeaf(_leafData(userAlice, address(token2), 200 ether));
        
        bytes32 root = merkleTree.root();

        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmTest");

        // Claim token1
        vm.prank(userAlice);
        distributor.claim(userAlice, address(token1), 100 ether, merkleTree.getProof(0));
        assertEq(token1.balanceOf(userAlice), 100 ether);

        // Claim token2
        vm.prank(userAlice);
        distributor.claim(userAlice, address(token2), 200 ether, merkleTree.getProof(1));
        assertEq(token2.balanceOf(userAlice), 200 ether);
    }

    function test_PreviewClaim_ReturnsClaimableAmount() public {
        // Setup: Add leaf for Alice, token1, 100 ether
        uint256 claimAmount = 100 ether;
        merkleTree.pushLeaf(_leafData(userAlice, address(token1), claimAmount));
        bytes32 root = merkleTree.root();
        bytes32[] memory proof = merkleTree.getProof(0);

        vm.prank(manager);
        distributor.setMerkleRoot(root, "QmPreviewTest");

        // Preview before any claim; claimable should be 100 ether
        uint256 preview = distributor.previewClaim(userAlice, address(token1), claimAmount, proof);
        assertEq(preview, 100 ether);

        // Claim the amount
        vm.prank(userAlice);
        distributor.claim(userAlice, address(token1), claimAmount, proof);

        // Preview after claim; should revert with ClaimableTooLow
        vm.expectRevert(Distributor.ClaimableTooLow.selector);
        distributor.previewClaim(userAlice, address(token1), claimAmount, proof);

        // Set root with higher cumulative amount
        uint256 newClaimAmount = 150 ether;
        MerkleTree newTree = new MerkleTree();
        newTree.pushLeaf(_leafData(userAlice, address(token1), newClaimAmount));
        bytes32 newRoot = newTree.root();
        bytes32[] memory newProof = newTree.getProof(0);

        vm.prank(manager);
        distributor.setMerkleRoot(newRoot, "QmPreviewTest2");

        // Preview claimable (should be 50 ether, since 100 already claimed)
        uint256 preview2 = distributor.previewClaim(userAlice, address(token1), newClaimAmount, newProof);
        assertEq(preview2, 50 ether);
    }
}
