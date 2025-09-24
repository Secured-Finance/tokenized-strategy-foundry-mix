// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Setup} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // TODO: add additional check on strat params
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Calculate max loss expected
        uint256[] memory maturities = strategy.getTargetMaturities();
        uint256 maxLossExpected = 0;
        for (uint256 i = 0; i < maturities.length; i++) {
            maxLossExpected += calculateMaxLossExpected(maturities[i], _amount);
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        changeMarketPrice(maturities[0], 1);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertLe(loss, maxLossExpected, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(
            strategy.convertToAssets(strategy.balanceOf(user)),
            availableWithdrawLimit
        );

        vm.prank(user);
        strategy.withdraw(withdrawableAmount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + withdrawableAmount,
            "!final balance"
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;

        // Calculate max loss expected
        uint256[] memory maturities = strategy.getTargetMaturities();
        uint256 maxDepositLossExpected = 0;
        uint256 maxAirdropLossExpected = 0;
        for (uint256 i = 0; i < maturities.length; i++) {
            maxDepositLossExpected += calculateMaxLossExpected(
                maturities[i],
                _amount
            );
            maxAirdropLossExpected += calculateMaxLossExpected(
                maturities[i],
                toAirdrop
            );
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Report profit
        vm.prank(keeper);
        (, uint256 loss1) = strategy.report();

        // Earn Interest
        changeMarketPrice(maturities[0], 1);

        // TODO: implement logic to simulate earning interest.
        airdrop(asset, address(strategy), toAirdrop);

        vm.prank(keeper);
        strategy.tend();

        // Report profit
        vm.prank(keeper);
        (uint256 profit2, uint256 loss2) = strategy.report();

        // Check return Values
        assertLe(
            toAirdrop,
            profit2 + maxAirdropLossExpected + loss1,
            "!profit"
        );
        assertEq(loss2, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(
            strategy.convertToAssets(strategy.balanceOf(user)),
            availableWithdrawLimit
        );

        vm.prank(user);
        strategy.withdraw(withdrawableAmount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + withdrawableAmount,
            "!final balance"
        );
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Calculate max loss expected
        uint256[] memory maturities = strategy.getTargetMaturities();
        uint256 maxDepositLossExpected = 0;
        uint256 maxAirdropLossExpected = 0;
        for (uint256 i = 0; i < maturities.length; i++) {
            maxDepositLossExpected += calculateMaxLossExpected(
                maturities[i],
                _amount
            );
            maxAirdropLossExpected += calculateMaxLossExpected(
                maturities[i],
                toAirdrop
            );
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Report profit
        vm.prank(keeper);
        (, uint256 loss1) = strategy.report();

        // Earn Interest
        changeMarketPrice(maturities[0], 1);

        // TODO: implement logic to simulate earning interest.
        airdrop(asset, address(strategy), toAirdrop);

        vm.prank(keeper);
        strategy.tend();

        // Report profit
        vm.prank(keeper);
        (uint256 profit2, uint256 loss2) = strategy.report();

        // Check return Values
        assertLe(
            toAirdrop,
            profit2 + maxAirdropLossExpected + loss1,
            "!profit"
        );
        assertEq(loss2, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit2 * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        // Place lend orders for unwinding
        for (uint256 i = 0; i < maturities.length; i++) {
            placeLendOrderAtMarketUnitPrice(maturities[i], _amount);
        }

        // Withdraw all funds
        {
            uint256 balanceBefore = asset.balanceOf(user);
            // Withdraw all funds
            uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(
                user
            );
            uint256 withdrawableAmount = Math.min(
                strategy.convertToAssets(strategy.balanceOf(user)),
                availableWithdrawLimit
            );

            vm.prank(user);
            strategy.withdraw(withdrawableAmount, user, user);

            assertGe(
                asset.balanceOf(user),
                balanceBefore + withdrawableAmount,
                "!final balance"
            );
        }

        // Withdraw performance fee
        {
            uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(
                performanceFeeRecipient
            );
            uint256 withdrawableAmount = Math.min(
                strategy.convertToAssets(
                    strategy.balanceOf(performanceFeeRecipient)
                ),
                availableWithdrawLimit
            );

            if (withdrawableAmount > 0) {
                vm.prank(performanceFeeRecipient);
                strategy.withdraw(
                    withdrawableAmount,
                    performanceFeeRecipient,
                    performanceFeeRecipient
                );
            }
        }

        checkStrategyTotals(0, 0, 0);

        assertGe(
            asset.balanceOf(performanceFeeRecipient),
            expectedShares,
            "!perf fee out"
        );
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(10 minutes);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        uint256[] memory maturities = strategy.getTargetMaturities();

        // Place lend orders for unwinding
        for (uint256 i = 0; i < maturities.length; i++) {
            placeLendOrderAtMarketUnitPrice(maturities[i], _amount);
        }

        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(
            strategy.convertToAssets(strategy.balanceOf(user)),
            availableWithdrawLimit
        );

        vm.prank(user);
        strategy.withdraw(withdrawableAmount, user, user);

        vm.prank(keeper);
        strategy.tend();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}
