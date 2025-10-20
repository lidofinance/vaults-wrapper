// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Test, console} from "forge-std/Test.sol";

import {WrapperBHarness} from "test/utils/WrapperBHarness.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {Factory} from "src/Factory.sol";
import {WrapperA} from "src/WrapperA.sol";
import {WrapperB} from "src/WrapperB.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";

/**
 * @title WrapperBTest
 * @notice Integration tests for WrapperB (minting, no strategy)
 */
contract WrapperBTest is WrapperBHarness {
    function setUp() public {
        _initializeCore();
    }

    uint256 public constant DEFAULT_WRAPPER_RR_GAP = 1000; // 10%

    function test_single_user_mints_full_in_one_step() public {
        WrapperContext memory ctx = _deployWrapperB(false, 0, 0);
        _assertUniversalInvariants("Step 0", ctx);
        _checkInitialState(ctx);

        //
        // Step 1: User deposits ETH
        //
        uint256 user1Deposit = 10_000 wei;
        uint256 user1ExpectedMintableStethShares = _calcMaxMintableStShares(ctx, user1Deposit);

        vm.prank(USER1);
        wrapperB(ctx).depositETH{value: user1Deposit}(USER1, address(0), 0);

        _assertUniversalInvariants("Step 1", ctx);

        assertEq(steth.sharesOf(USER1), 0, "stETH shares balance of USER1 should be equal to 0");
        assertEq(
            wrapperB(ctx).mintingCapacitySharesOf(USER1),
            user1ExpectedMintableStethShares,
            "Mintable stETH shares should equal capacity derived from assets"
        );
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER1, ctx.wrapper.balanceOf(USER1)),
            0,
            "stETH shares for withdrawal should be equal to 0"
        );
        assertEq(ctx.dashboard.liabilityShares(), 0, "Vault's liability shares should be equal to 0");
        assertEq(ctx.dashboard.totalValue(), CONNECT_DEPOSIT + user1Deposit, "Vault's total value should be equal to CONNECT_DEPOSIT + user1Deposit");

        assertGt(
            ctx.dashboard.remainingMintingCapacityShares(0),
            0,
            "Remaining minting capacity should be greater than 0"
        );

        //
        // Step 2: User mints all available stETH shares in one step
        //

        vm.prank(USER1);
        wrapperB(ctx).mintStethShares(user1ExpectedMintableStethShares);

        vm.clearMockedCalls();

        _assertUniversalInvariants("Step 2", ctx);

        assertEq(
            steth.sharesOf(USER1),
            user1ExpectedMintableStethShares,
            "stETH shares balance of USER1 should be equal to user1ExpectedMintableStethShares"
        );
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER1, ctx.wrapper.balanceOf(USER1)),
            user1ExpectedMintableStethShares,
            "stETH shares for withdrawal should be equal to user1ExpectedMintableStethShares"
        );
        assertEq(
            ctx.dashboard.liabilityShares(),
            user1ExpectedMintableStethShares,
            "Vault's liability shares should be equal to user1ExpectedMintableStethShares"
        );
        // Still remaining capacity is higher due to CONNECT_DEPOSIT
        assertGt(
            ctx.dashboard.remainingMintingCapacityShares(0), 0, "Remaining minting capacity should be greater than 0"
        );
        assertEq(wrapperB(ctx).mintingCapacitySharesOf(USER1), 0, "Mintable stETH shares should be equal to 0");
    }

    function test_depositETH_with_max_mintable_amount() public {
        WrapperContext memory ctx = _deployWrapperB(false, 0, 0);

        //
        // Step 1: User deposits ETH and mints max stETH shares in one transaction using MAX_MINTABLE_AMOUNT
        //
        uint256 user1Deposit = 10_000 wei;
        uint256 user1ExpectedMintableStethShares = _calcMaxMintableStShares(ctx, user1Deposit);

        vm.prank(USER1);
        wrapperB(ctx).depositETH{value: user1Deposit}(USER1, address(0), wrapperB(ctx).MAX_MINTABLE_AMOUNT());

        _assertUniversalInvariants("Step 1", ctx);

        assertEq(
            steth.sharesOf(USER1),
            user1ExpectedMintableStethShares,
            "stETH shares balance of USER1 should equal max mintable for deposit"
        );
        assertEq(
            wrapperB(ctx).mintedStethSharesOf(USER1),
            user1ExpectedMintableStethShares,
            "Minted stETH shares should equal expected"
        );
        assertEq(
            ctx.dashboard.liabilityShares(),
            user1ExpectedMintableStethShares,
            "Vault's liability shares should equal minted shares"
        );
        assertEq(wrapperB(ctx).mintingCapacitySharesOf(USER1), 0, "No additional mintable shares should remain");

        //
        // Step 2: User deposits more ETH and mints max for new deposit
        //
        uint256 user1Deposit2 = 15_000 wei;
        uint256 user1ExpectedMintableStethShares2 = _calcMaxMintableStShares(ctx, user1Deposit2);

        vm.prank(USER1);
        wrapperB(ctx).depositETH{value: user1Deposit2}(USER1, address(0), wrapperB(ctx).MAX_MINTABLE_AMOUNT());

        _assertUniversalInvariants("Step 2", ctx);

        assertEq(
            steth.sharesOf(USER1),
            user1ExpectedMintableStethShares + user1ExpectedMintableStethShares2,
            "stETH shares should equal sum of both deposits"
        );
        assertEq(
            ctx.dashboard.liabilityShares(),
            user1ExpectedMintableStethShares + user1ExpectedMintableStethShares2,
            "Vault's liability should equal sum of both minted amounts"
        );
    }

    function test_single_user_mints_full_in_two_steps() public {
        WrapperContext memory ctx = _deployWrapperB(false, 0, 0);

        //
        // Step 1
        //
        uint256 user1Deposit = 10_000 wei;
        uint256 user1ExpectedMintableStethShares = _calcMaxMintableStShares(ctx, user1Deposit);

        vm.prank(USER1);
        wrapperB(ctx).depositETH{value: user1Deposit}(USER1, address(0), 0);

        // _assertUniversalInvariants("Step 1");

        assertEq(steth.sharesOf(USER1), 0, "stETH shares balance of USER1 should be equal to 0");
        assertEq(
            wrapperB(ctx).mintingCapacitySharesOf(USER1),
            user1ExpectedMintableStethShares,
            "Mintable stETH shares should be equal to 0"
        );
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER1, ctx.wrapper.balanceOf(USER1)),
            0,
            "stETH shares for withdrawal should be equal to 0"
        );
        assertEq(ctx.dashboard.liabilityShares(), 0, "Vault's liability shares should be equal to 0");

        // Due to CONNECT_DEPOSIT counted by vault as eth for reserve vaults minting capacity is higher than for the user
        assertGt(
            ctx.dashboard.remainingMintingCapacityShares(0),
            user1ExpectedMintableStethShares,
            "Remaining minting capacity should be equal to 0"
        );

        //
        // Step 2
        //
        uint256 user1StSharesPart1 = user1ExpectedMintableStethShares / 3;

        vm.prank(USER1);
        wrapperB(ctx).mintStethShares(user1StSharesPart1);

        _assertUniversalInvariants("Step 2", ctx);

        assertEq(
            steth.sharesOf(USER1),
            user1StSharesPart1,
            "stETH shares balance of USER1 should be equal to user1StSharesToMint"
        );
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER1, ctx.wrapper.balanceOf(USER1)),
            user1StSharesPart1,
            "stETH shares for withdrawal should be equal to user1StSharesToMint"
        );
        assertEq(
            ctx.dashboard.liabilityShares(),
            user1StSharesPart1,
            "Vault's liability shares should be equal to user1StSharesToMint"
        );
        // Still remaining capacity is higher due to CONNECT_DEPOSIT
        assertGt(
            ctx.dashboard.remainingMintingCapacityShares(0),
            user1ExpectedMintableStethShares - user1StSharesPart1,
            "Remaining minting capacity should be equal to user1ExpectedMintableStethShares - user1StSharesToMint"
        );
        assertEq(
            wrapperB(ctx).mintingCapacitySharesOf(USER1),
            user1ExpectedMintableStethShares - user1StSharesPart1,
            "Remaining mintable should reduce exactly by minted part"
        );

        uint256 user1StSharesPart2 = user1ExpectedMintableStethShares - user1StSharesPart1;

        //
        // Step 3
        //
        vm.prank(USER1);
        wrapperB(ctx).mintStethShares(user1StSharesPart2);

        _assertUniversalInvariants("Step 3", ctx);

        assertEq(
            steth.sharesOf(USER1),
            user1ExpectedMintableStethShares,
            "stETH shares balance of USER1 should be equal to user1StSharesToMint"
        );
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER1, ctx.wrapper.balanceOf(USER1)),
            user1ExpectedMintableStethShares,
            "stETH shares for withdrawal should be equal to user1StSharesToMint"
        );
        assertEq(
            ctx.dashboard.liabilityShares(),
            user1ExpectedMintableStethShares,
            "Vault's liability shares should be equal to user1StSharesToMint"
        );
        // Still remaining capacity is higher due to CONNECT_DEPOSIT
        assertGt(ctx.dashboard.remainingMintingCapacityShares(0), 0, "Remaining minting capacity should be equal to 0");
        assertEq(wrapperB(ctx).mintingCapacitySharesOf(USER1), 0, "Mintable stETH shares should be equal to 0");
    }

    function test_two_users_mint_full_in_two_steps() public {
        WrapperContext memory ctx = _deployWrapperB(false, 0, 0);

        //
        // Step 1: User1 deposits ETH
        //
        uint256 user1Deposit = 10_000 wei;
        uint256 user1ExpectedMintableStethShares = _calcMaxMintableStShares(ctx, user1Deposit);

        vm.prank(USER1);
        wrapperB(ctx).depositETH{value: user1Deposit}(USER1, address(0), 0);

        assertEq(steth.sharesOf(USER1), 0, "stETH shares balance of USER1 should be equal to 0");
        assertEq(
            wrapperB(ctx).mintingCapacitySharesOf(USER1),
            user1ExpectedMintableStethShares,
            "Mintable stETH shares for USER1 should equal expected"
        );
        assertEq(ctx.dashboard.liabilityShares(), 0, "Vault's liability shares should be equal to 0");

        //
        // Step 2: User2 deposits ETH
        //
        uint256 user2Deposit = 15_000 wei;
        uint256 user2ExpectedMintableStethShares = _calcMaxMintableStShares(ctx, user2Deposit);

        vm.prank(USER2);
        wrapperB(ctx).depositETH{value: user2Deposit}(USER2, address(0), 0);

        assertEq(steth.sharesOf(USER2), 0, "stETH shares balance of USER2 should be equal to 0");
        assertEq(
            wrapperB(ctx).mintingCapacitySharesOf(USER2),
            user2ExpectedMintableStethShares,
            "Mintable stETH shares for USER2 should equal expected"
        );
        assertEq(
            ctx.dashboard.liabilityShares(), 0, "Vault's liability shares should be equal to 0 after deposits only"
        );
        // Due to CONNECT_DEPOSIT capacity should comfortably allow minting
        assertGt(
            ctx.dashboard.remainingMintingCapacityShares(0),
            user1ExpectedMintableStethShares,
            "Remaining capacity should exceed USER1 expected"
        );
        assertGt(
            ctx.dashboard.remainingMintingCapacityShares(0),
            user2ExpectedMintableStethShares,
            "Remaining capacity should exceed USER2 expected"
        );

        //
        // Step 3: USER1 mints part of their available stETH shares
        //
        uint256 user1StSharesPart1 = user1ExpectedMintableStethShares / 3;

        vm.prank(USER1);
        wrapperB(ctx).mintStethShares(user1StSharesPart1);

        _assertUniversalInvariants("Step 3", ctx);

        assertEq(steth.sharesOf(USER1), user1StSharesPart1, "USER1 stETH shares should equal part1 minted");
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER1, ctx.wrapper.balanceOf(USER1)),
            user1StSharesPart1,
            "USER1 stSharesForWithdrawal should equal part1 minted"
        );
        assertEq(
            wrapperB(ctx).mintingCapacitySharesOf(USER1),
            user1ExpectedMintableStethShares - user1StSharesPart1,
            "USER1 remaining mintable should decrease by part1"
        );
        assertEq(
            ctx.dashboard.liabilityShares(), user1StSharesPart1, "Liability shares should equal USER1 minted so far"
        );

        //
        // Step 4: USER2 mints part of their available stETH shares
        //
        uint256 user2StSharesPart1 = user2ExpectedMintableStethShares / 3;

        vm.prank(USER2);
        wrapperB(ctx).mintStethShares(user2StSharesPart1);

        _assertUniversalInvariants("Step 4", ctx);

        assertEq(steth.sharesOf(USER2), user2StSharesPart1, "USER2 stETH shares should equal part1 minted");
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER2, ctx.wrapper.balanceOf(USER2)),
            user2StSharesPart1,
            "USER2 stSharesForWithdrawal should equal part1 minted"
        );
        assertEq(
            wrapperB(ctx).mintingCapacitySharesOf(USER2),
            user2ExpectedMintableStethShares - user2StSharesPart1,
            "USER2 remaining mintable should decrease by part1"
        );
        assertEq(
            ctx.dashboard.liabilityShares(),
            user1StSharesPart1 + user2StSharesPart1,
            "Liability shares should equal sum of minted parts"
        );

        //
        // Step 5: USER1 mints the rest
        //
        uint256 user1StSharesPart2 = user1ExpectedMintableStethShares - user1StSharesPart1;

        vm.prank(USER1);
        wrapperB(ctx).mintStethShares(user1StSharesPart2);

        _assertUniversalInvariants("Step 5", ctx);

        assertEq(
            steth.sharesOf(USER1),
            user1ExpectedMintableStethShares,
            "USER1 stETH shares should equal full expected after second mint"
        );
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER1, ctx.wrapper.balanceOf(USER1)),
            user1ExpectedMintableStethShares,
            "USER1 stSharesForWithdrawal should equal full expected"
        );
        assertEq(wrapperB(ctx).mintingCapacitySharesOf(USER1), 0, "USER1 remaining mintable should be zero");
        assertEq(
            ctx.dashboard.liabilityShares(),
            user1ExpectedMintableStethShares + user2StSharesPart1,
            "Liability shares should reflect USER1 full + USER2 part1"
        );

        //
        // Step 6: USER2 mints the rest
        //
        uint256 user2StSharesPart2 = user2ExpectedMintableStethShares - user2StSharesPart1;

        vm.prank(USER2);
        wrapperB(ctx).mintStethShares(user2StSharesPart2);

        _assertUniversalInvariants("Step 6", ctx);

        assertEq(
            steth.sharesOf(USER2),
            user2ExpectedMintableStethShares,
            "USER2 stETH shares should equal full expected after second mint"
        );
        assertEq(
            wrapperB(ctx).stethSharesForWithdrawal(USER2, ctx.wrapper.balanceOf(USER2)),
            user2ExpectedMintableStethShares,
            "USER2 stSharesForWithdrawal should equal full expected"
        );
        assertEq(wrapperB(ctx).mintingCapacitySharesOf(USER2), 0, "USER2 remaining mintable should be zero");
        // Still remaining capacity is higher due to CONNECT_DEPOSIT
        assertGt(
            ctx.dashboard.remainingMintingCapacityShares(0), 0, "Remaining minting capacity should be greater than 0"
        );
        assertEq(
            ctx.dashboard.liabilityShares(),
            user1ExpectedMintableStethShares + user2ExpectedMintableStethShares,
            "Liability shares should equal sum of both users' full mints"
        );
    }

    function test_vault_underperforms() public {
        WrapperContext memory ctx = _deployWrapperB(false, 0, 0);

        //
        // Step 1: User1 deposits
        //
        uint256 user1Deposit = 200 ether;
        uint256 user1ExpectedMintable = _calcMaxMintableStShares(ctx, user1Deposit);
        vm.prank(USER1);
        wrapperB(ctx).depositETH{value: user1Deposit}(USER1, address(0), user1ExpectedMintable);

        assertEq(steth.sharesOf(USER1), user1ExpectedMintable, "USER1 stETH shares should equal expected minted");
        assertEq(wrapperB(ctx).mintingCapacitySharesOf(USER1), 0, "USER1 remaining mintable should be zero");
        assertGt(
            ctx.dashboard.remainingMintingCapacityShares(0),
            0,
            "USER1 minting capacity shares should be equal to user1Deposit"
        );

        _assertUniversalInvariants("Step 1", ctx);

        vm.warp(block.timestamp + 1 days);
        reportVaultValueChangeNoFees(ctx, 100_00 - 100); // 99%

        uint256 user2Deposit = 10_000 wei;
        vm.prank(USER2);
        wrapperB(ctx).depositETH{value: user2Deposit}(USER2, address(0), 0);

        {
            uint256 user2ExpectedMintableStethShares = _calcMaxMintableStShares(ctx, user2Deposit);
            assertLe(
                wrapperB(ctx).mintingCapacitySharesOf(USER2),
                user2ExpectedMintableStethShares,
                "USER2 mintable stETH shares should not exceed expected after underperformance"
            );
        }

        // TODO: is this a correct check?
        // assertEq(steth.sharesOf(USER2), _calcMaxMintableStShares(ctx, user2Deposit), "USER2 stETH shares should be equal to user2Deposit");

        _assertUniversalInvariants("Step 2", ctx);
    }

    function test_user_withdraws_without_burning() public {
        WrapperContext memory ctx = _deployWrapperB(false, 0, 0);
        WrapperB w = wrapperB(ctx);

        //
        // Step 1: User1 deposits
        //
        uint256 user1Deposit = 2 * ctx.withdrawalQueue.MIN_WITHDRAWAL_AMOUNT() * 100; // * 100 to have +1% rewards enough for min withdrawal

        uint256 sharesForDeposit = _calcMaxMintableStShares(ctx, user1Deposit);
        vm.prank(USER1);
        w.depositETH{value: user1Deposit}(USER1, address(0), sharesForDeposit);

        uint256 expectedUser1MintedStShares = sharesForDeposit;
        assertEq(
            steth.sharesOf(USER1),
            expectedUser1MintedStShares,
            "USER1 stETH shares should be equal to expectedUser1MintedStShares"
        );
        assertEq(w.mintingCapacitySharesOf(USER1), 0, "USER1 mintable stETH shares should be equal to 0");
        assertEq(
            w.stethSharesForWithdrawal(USER1, w.balanceOf(USER1)),
            expectedUser1MintedStShares,
            "USER1 stSharesForWithdrawal should be equal to expectedUser1MintedStShares"
        );
        // assertEq(ctx.dashboard.liabilityShares(), expectedUser1MintedStShares, "Vault's liability shares should be equal to expectedUser1MintedStShares");
        // assertGt(ctx.dashboard.remainingMintingCapacityShares(0), 0, "Remaining minting capacity should be greater than 0");

        reportVaultValueChangeNoFees(ctx, 100_00 + 100); // +1%
        uint256 user1Rewards = user1Deposit * 100 / 10000;
        assertApproxEqAbs(
            w.previewRedeem(w.balanceOf(USER1)),
            user1Deposit + user1Rewards,
            WEI_ROUNDING_TOLERANCE,
            "USER1 previewRedeem should be equal to user1Deposit + user1Rewards"
        );

        // TODO: handle 1 wei problem here
        uint256 expectedRewardsShares = _calcMaxMintableStShares(ctx, user1Rewards);
        assertApproxEqAbs(
            w.mintingCapacitySharesOf(USER1),
            expectedRewardsShares,
            WEI_ROUNDING_TOLERANCE,
            "USER1 mintable stETH shares should equal capacity from rewards"
        );

        assertEq(w.withdrawableEthOf(USER1, 0), user1Rewards, "USER1 withdrawable eth should be equal to user1Rewards");
        assertEq(w.withdrawableEthOf(USER1, expectedUser1MintedStShares), w.previewRedeem(w.balanceOf(USER1)), "USER1 withdrawable eth should be equal to user1Deposit + user1Rewards");

        assertEq(w.stethSharesForWithdrawal(USER1, w.balanceOf(USER1)), expectedUser1MintedStShares, "USER1 stSharesForWithdrawal should be equal to expectedUser1MintedStShares");

        uint256 rewardsStv =
            Math.mulDiv(user1Rewards, w.balanceOf(USER1), user1Deposit + user1Rewards, Math.Rounding.Floor);
        // TODO: fix fail here
        assertLe(
            w.stethSharesForWithdrawal(USER1, rewardsStv), WEI_ROUNDING_TOLERANCE,
            "USER1 stSharesForWithdrawal for rewards-only should be ~0"
        );
        assertEq(w.stethSharesForWithdrawal(USER1, rewardsStv), 0, "USER1 stSharesForWithdrawal should be equal to 0");

        _assertUniversalInvariants("Step 1", ctx);

        //
        // Step 2.0: User1 withdraws rewards without burning any stethShares
        //
        uint256 withdrawableStvWithoutBurning = w.withdrawableStvOf(USER1, 0);

        assertEq(
            withdrawableStvWithoutBurning, rewardsStv, "Withdrawable stv should be equal to rewardsStv"
        );

        vm.prank(USER1);
        uint256 requestId = w.requestWithdrawal(rewardsStv, 0, 0, USER1);
        // same as: uint256 requestId = w.requestWithdrawal(rewardsStv);

        WithdrawalQueue.WithdrawalRequestStatus memory status = ctx.withdrawalQueue.getWithdrawalStatus(requestId);
        assertEq(status.amountOfAssets, user1Rewards, "Withdrawal request amount should match previewRedeem");

        // Update report data with current timestamp to make it fresh
        core.applyVaultReport(address(ctx.vault), w.totalAssets(), 0, 0, 0);

        _advancePastMinDelayAndRefreshReport(ctx, requestId);
        vm.prank(NODE_OPERATOR);
        ctx.withdrawalQueue.finalize(1);

        status = ctx.withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isFinalized, "Withdrawal request should be finalized");
        assertEq(status.amountOfAssets, user1Rewards, "Withdrawal request amount should match previewRedeem");
        assertEq(status.amountOfStv, rewardsStv, "Withdrawal request shares should match user1SharesToWithdraw");

        // Deal ETH to withdrawal queue for the claim (simulating validator exit)
        vm.deal(address(ctx.withdrawalQueue), address(ctx.withdrawalQueue).balance + user1Rewards);

        uint256 totalClaimed;

        // User1 claims their withdrawal
        uint256 user1EthBalanceBeforeClaim = USER1.balance;
        vm.prank(USER1);
        w.claimWithdrawal(requestId, USER1);

        assertApproxEqAbs(
            USER1.balance,
            user1EthBalanceBeforeClaim + user1Rewards,
            WEI_ROUNDING_TOLERANCE,
            _contextMsg("Step 2", "USER1 ETH balance should increase by the withdrawn amount")
        );
        totalClaimed += user1Rewards;

        //
        // Step 2.1: User1 tries to withdraw stv corresponding to 1 wei but RequestAmountTooSmall
        //

        uint256 stvFor1Wei = w.previewWithdraw(1 wei);
        assertGt(w.balanceOf(USER1), stvFor1Wei, "USER1 stv balance should be greater than stvFor1Wei");

        vm.startPrank(USER1);
        vm.expectRevert(WrapperB.InsufficientReservedBalance.selector);
        w.requestWithdrawal(stvFor1Wei);
        vm.stopPrank();

        //
        // Step 2.2: User1 tries to withdraw stv without burning any stethShares but fails
        //
        uint256 stvForMinWithdrawal = w.previewWithdraw(ctx.withdrawalQueue.MIN_WITHDRAWAL_AMOUNT());
        uint256 stethSharesToBurn = w.stethSharesForWithdrawal(USER1, stvForMinWithdrawal);
        console.log("stethSharesToBurn", stethSharesToBurn);

        vm.startPrank(USER1);

        vm.expectRevert(WrapperB.InsufficientReservedBalance.selector);
        w.requestWithdrawal(stvForMinWithdrawal);

        steth.approve(address(w), steth.getPooledEthByShares(stethSharesToBurn));
        vm.expectRevert(WrapperB.InsufficientReservedBalance.selector);
        w.requestWithdrawal(stvForMinWithdrawal);

        steth.increaseAllowance(address(w), steth.getPooledEthByShares(1));

        uint256 user1StethSharesBefore = steth.balanceOf(USER1);
        uint256 wqStethSharesBefore = steth.balanceOf(address(ctx.withdrawalQueue));
        requestId = w.requestWithdrawal(stvForMinWithdrawal);

        vm.stopPrank();

        assertEq(
            user1StethSharesBefore - steth.balanceOf(USER1),
            stethSharesToBurn,
            "USER1 stETH shares should decrease by wstethToBurn"
        );
        assertApproxEqAbs(
            steth.balanceOf(address(ctx.withdrawalQueue)) - wqStethSharesBefore,
            stethSharesToBurn,
            WEI_ROUNDING_TOLERANCE,
            _contextMsg("Step 2", "WithdrawalQueue stETH shares should increase by wstethToBurn")
        );

//        // Finalize and claim the second (min-withdrawal) request
//        _advancePastMinDelayAndRefreshReport(ctx, requestId);
//        vm.prank(NODE_OPERATOR);
//        ctx.withdrawalQueue.finalize(1);
//
//        status = ctx.withdrawalQueue.getWithdrawalStatus(requestId);
//        assertTrue(status.isFinalized, "Min-withdrawal request should be finalized");
//
//        // Ensure queue has enough ETH to claim
//        vm.deal(address(ctx.withdrawalQueue), address(ctx.withdrawalQueue).balance + status.amountOfAssets);
//
//        uint256 user1EthBefore2 = USER1.balance;
//        vm.prank(USER1);
//        w.claimWithdrawal(requestId, USER1);
//
//        assertApproxEqAbs(
//            USER1.balance,
//            user1EthBefore2 + status.amountOfAssets,
//            WEI_ROUNDING_TOLERANCE,
//            _contextMsg("Step 2", "USER1 ETH balance should increase by the withdrawn amount (min withdrawal)")
//        );
//        totalClaimed += status.amountOfAssets;
//
//        // =======================
//        // Step 3: Withdraw the rest fully
//        // =======================
//        uint256 remainingStv = w.balanceOf(USER1);
//        if (remainingStv > 0) {
//            uint256 burnForRest = w.stethSharesForWithdrawal(USER1, remainingStv);
//
//            vm.startPrank(USER1);
//            steth.approve(address(w), steth.getPooledEthByShares(burnForRest));
//            uint256 requestId3 = w.requestWithdrawal(remainingStv, burnForRest);
//            vm.stopPrank();
//
//            _advancePastMinDelayAndRefreshReport(ctx, requestId3);
//            vm.prank(NODE_OPERATOR);
//            ctx.withdrawalQueue.finalize(1);
//
//            WithdrawalQueue.WithdrawalRequestStatus memory st3 = ctx.withdrawalQueue.getWithdrawalStatus(requestId3);
//            assertTrue(st3.isFinalized, "Final full-withdrawal request should be finalized");
//            vm.deal(address(ctx.withdrawalQueue), address(ctx.withdrawalQueue).balance + st3.amountOfAssets);
//
//            uint256 user1EthBefore3 = USER1.balance;
//            vm.prank(USER1);
//            w.claimWithdrawal(requestId3, USER1);
//
//            assertApproxEqAbs(
//                USER1.balance,
//                user1EthBefore3 + st3.amountOfAssets,
//                WEI_ROUNDING_TOLERANCE,
//                _contextMsg("Step 3", "USER1 ETH balance should increase by the withdrawn amount (final)")
//            );
//            totalClaimed += st3.amountOfAssets;
//        }
//
//        // Final assertions: user fully withdrawn
//        assertEq(w.balanceOf(USER1), 0, "USER1 should have zero stv after full withdrawal");
//        assertEq(w.mintedStethSharesOf(USER1), 0, "USER1 should have zero minted stETH shares after full withdrawal");
//
//        // Total claimed should be equal to deposit + rewards (within tolerance)
//        assertApproxEqAbs(
//            totalClaimed,
//            user1Deposit + user1Rewards,
//            WEI_ROUNDING_TOLERANCE,
//            _contextMsg("Final", "Total claimed should equal deposit + rewards")
//        );
    }
}
