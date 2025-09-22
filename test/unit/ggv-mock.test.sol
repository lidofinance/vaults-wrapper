// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {GGVVaultMock, GGVMockTeller,GGVQueueMock} from "src/mock/GGVMock.sol";
import {MockStETH} from "test/mocks/MockStETH.sol";



contract GGVMockTest is Test {
    GGVVaultMock public vault;
    GGVMockTeller public teller;
    GGVQueueMock public queue;
    MockStETH public steth;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public operator = address(0x3);
    address public admin = address(0x4);

    uint256 public constant initialBalance = 100 ether;

    function setUp() public {
        vm.deal(user1, initialBalance);
        vm.deal(user2, initialBalance);
        vm.deal(admin, initialBalance);
        vm.deal(operator, initialBalance);

        steth = new MockStETH();
        // give admin 10 steth for ggv rebase
        vm.prank(admin);
        steth.submit{value: 10 ether}(admin);
        
    
        vault = new GGVVaultMock(admin, address(steth));
        teller = GGVMockTeller(address(vault.TELLER()));
        queue = GGVQueueMock(address(vault.BORING_QUEUE()));

        // approve admin's steth for ggv rebase
        vm.prank(admin);
        steth.approve(address(vault), type(uint256).max);

    }

    function test_depositToGGV() public {

        vm.startPrank(user1);
        uint256 userStethShares = steth.submit{value: 1 ether}(address(0));
        assertEq(userStethShares, steth.sharesOf(user1));
        assertEq(steth.balanceOf(user1), 1 ether);

        steth.approve(address(vault), type(uint256).max);
        uint256 ggvShares = teller.deposit(steth, 1 ether, 0);
        assertEq(ggvShares, vault.balanceOf(user1));
        uint256 ggvUserAssets = vault.getAssetsByShares(ggvShares);
        vm.stopPrank();

        vm.startPrank(admin); 
        vault.rebase(1 ether);
        uint256 newGgvUserAssets = vault.getAssetsByShares(ggvShares);
        assertEq(newGgvUserAssets > ggvUserAssets, true);
    }
}