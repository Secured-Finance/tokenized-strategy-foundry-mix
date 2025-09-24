pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Setup} from "./utils/Setup.sol";

contract ShutdownTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        uint256[] memory maturities = strategy.getTargetMaturities();
        changeMarketPrice(maturities[0], 1);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(_amount, availableWithdrawLimit);
        vm.prank(user);
        strategy.redeem(withdrawableAmount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + withdrawableAmount,
            "!final balance"
        );
    }

    function test_emergencyWithdraw_maxUint(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        uint256[] memory maturities = strategy.getTargetMaturities();
        changeMarketPrice(maturities[0], 1);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        uint256 availableWithdrawLimit = strategy.availableWithdrawLimit(user);
        uint256 withdrawableAmount = Math.min(_amount, availableWithdrawLimit);

        vm.prank(user);
        strategy.redeem(withdrawableAmount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + withdrawableAmount,
            "!final balance"
        );
    }

    // TODO: Add tests for any emergency function added.
}
