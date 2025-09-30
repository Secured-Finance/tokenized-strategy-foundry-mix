// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Setup} from "./utils/Setup.sol";

contract OperationTest is Setup {
    uint256 public constant MAX_ROUNDING_ERROR = 2;

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

        // Place a borrow order with large amount to ensure filling all orders at market unit price
        for (uint256 i = 0; i < maturities.length; i++) {
            placeBorrowOrderAtMarketUnitPrice(maturities[i], 1e36, false);
            cancelBorrowOrders(management, maturities[i]);
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Place lend orders for unwinding
        for (uint256 i = 0; i < maturities.length; i++) {
            placeLendOrderAtMarketUnitPrice(maturities[i], 1e36, false);
        }

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(
            strategy.convertToAssets(strategy.balanceOf(user)),
            availableWithdrawLimit
        );

        vm.prank(user);
        strategy.withdraw(withdrawableAmount, user, user);

        assertEq(
            asset.balanceOf(user),
            balanceBefore + withdrawableAmount,
            "!final balance"
        );
    }

    function test_operation_withFilledOrders(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Calculate max loss expected
        uint256[] memory maturities = strategy.getTargetMaturities();

        // Place a borrow order with large amount to ensure filling all orders at market unit price
        for (uint256 i = 0; i < maturities.length; i++) {
            placeBorrowOrderAtMarketUnitPrice(maturities[i], 1e36, false);
            cancelBorrowOrders(management, maturities[i]);
        }
        // Place a borrow order for 5% of deposited amount to ensure filling the strategy's orders.
        uint256 borrowAmount = (_amount * 5) / 100;
        placeBorrowOrderAtMarketUnitPrice(maturities[0], borrowAmount, false);
        uint256 maxDepositLossExpected = calculateMaxLossExpected(
            maturities[0],
            borrowAmount
        ) + MAX_ROUNDING_ERROR;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertLe(loss, maxDepositLossExpected, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Place lend orders for unwinding
        for (uint256 i = 0; i < maturities.length; i++) {
            placeLendOrderAtMarketUnitPrice(maturities[i], 1e36, false);
        }

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        (
            uint256 maxOrderLoss,
            uint256 orderFeeRate
        ) = calculateMaxUnwindingLossExpected(address(strategy), maturities[0]);
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(
            strategy.convertToAssets(strategy.balanceOf(user)),
            availableWithdrawLimit
        );

        vm.prank(user);
        strategy.withdraw(withdrawableAmount, user, user, orderFeeRate);

        assertGe(
            asset.balanceOf(user),
            balanceBefore +
                withdrawableAmount -
                maxOrderLoss -
                MAX_ROUNDING_ERROR,
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
        uint256 maxAirdropLossExpected = calculateMaxLossExpected(
            maturities[0],
            toAirdrop
        ) + MAX_ROUNDING_ERROR;

        // Place a borrow order with large amount to ensure filling all orders at market unit price
        for (uint256 i = 0; i < maturities.length; i++) {
            placeBorrowOrderAtMarketUnitPrice(maturities[i], 1e36, false);
            cancelBorrowOrders(management, maturities[i]);
        }
        // Place a borrow order for 5% of deposited amount to ensure filling the strategy's orders.
        uint256 borrowAmount = (_amount * 5) / 100;
        placeBorrowOrderAtMarketUnitPrice(maturities[0], borrowAmount, false);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Report profit
        vm.prank(keeper);
        (, uint256 loss1) = strategy.report();

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

        // Place lend orders for unwinding
        for (uint256 i = 0; i < maturities.length; i++) {
            placeLendOrderAtMarketUnitPrice(maturities[i], 1e36, false);
        }

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        (
            uint256 maxOrderLoss,
            uint256 orderFeeRate
        ) = calculateMaxUnwindingLossExpected(address(strategy), maturities[0]);
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(
            strategy.convertToAssets(strategy.balanceOf(user)),
            availableWithdrawLimit
        );

        vm.prank(user);
        strategy.withdraw(withdrawableAmount, user, user, orderFeeRate);

        assertGe(
            asset.balanceOf(user),
            balanceBefore +
                withdrawableAmount -
                maxOrderLoss -
                MAX_ROUNDING_ERROR,
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
        uint256 maxAirdropLossExpected = calculateMaxLossExpected(
            maturities[0],
            toAirdrop
        ) + MAX_ROUNDING_ERROR;

        // Place a borrow order with large amount to ensure filling all orders at market unit price
        for (uint256 i = 0; i < maturities.length; i++) {
            placeBorrowOrderAtMarketUnitPrice(maturities[i], 1e36, false);
            cancelBorrowOrders(management, maturities[i]);
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Report profit
        vm.prank(keeper);
        (, uint256 loss1) = strategy.report();

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
            placeLendOrderAtMarketUnitPrice(maturities[i], 1e36, false);
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

    function test_profitableReport_withFilledOrders(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Calculate max loss expected
        uint256[] memory maturities = strategy.getTargetMaturities();

        // Place a borrow order with large amount to ensure filling all orders at market unit price
        for (uint256 i = 0; i < maturities.length; i++) {
            placeBorrowOrderAtMarketUnitPrice(maturities[i], 1e36, false);
            cancelBorrowOrders(management, maturities[i]);
        }
        // Place a borrow order for 5% of deposited amount to ensure filling the strategy's orders.
        uint256 borrowAmount = (_amount * 5) / 100;
        placeBorrowOrderAtMarketUnitPrice(maturities[0], borrowAmount, false);
        uint256 maxDepositLossExpected = calculateMaxLossExpected(
            maturities[0],
            borrowAmount
        ) + MAX_ROUNDING_ERROR;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        (int256 presentValueBefore, ) = lendingMarketController.getPosition(
            currency,
            maturities[0],
            address(strategy)
        );
        assertGt(presentValueBefore, 0, "!presentValueBefore");

        // Earn Interest
        changeMarketPrice(maturities[0], 100);

        (int256 presentValueAfter, ) = lendingMarketController.getPosition(
            currency,
            maturities[0],
            address(strategy)
        );
        assertGt(presentValueAfter, 0, "!presentValueAfter");

        // Calculate expected profit
        uint256 expectedProfit = uint256(presentValueAfter) -
            uint256(presentValueBefore) -
            maxDepositLossExpected;

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, expectedProfit - MAX_ROUNDING_ERROR, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Place lend orders for unwinding
        for (uint256 i = 0; i < maturities.length; i++) {
            placeLendOrderAtMarketUnitPrice(maturities[i], 1e36, false);
        }

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        (
            uint256 maxOrderLoss,
            uint256 orderFeeRate
        ) = calculateMaxUnwindingLossExpected(address(strategy), maturities[0]);
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(
            strategy.convertToAssets(strategy.balanceOf(user)),
            availableWithdrawLimit
        );

        vm.prank(user);
        strategy.withdraw(withdrawableAmount, user, user, orderFeeRate);

        assertGe(
            asset.balanceOf(user),
            balanceBefore +
                withdrawableAmount -
                maxOrderLoss -
                MAX_ROUNDING_ERROR,
            "!final balance"
        );
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        uint256[] memory maturities = strategy.getTargetMaturities();

        // Place a borrow order with large amount to ensure filling all orders at market unit price
        for (uint256 i = 0; i < maturities.length; i++) {
            placeBorrowOrderAtMarketUnitPrice(maturities[i], 1e36, false);
            cancelBorrowOrders(management, maturities[i]);
        }

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

        // Place lend orders for unwinding
        for (uint256 i = 0; i < maturities.length; i++) {
            placeLendOrderAtMarketUnitPrice(maturities[i], 1e36, false);
        }

        uint256 orderFeeRate = lendingMarket.getOrderFeeRate();
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(
            strategy.convertToAssets(strategy.balanceOf(user)),
            availableWithdrawLimit
        );

        vm.prank(user);
        strategy.withdraw(withdrawableAmount, user, user, orderFeeRate);

        vm.prank(keeper);
        strategy.tend();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}
