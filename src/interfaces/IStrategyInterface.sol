// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ILendingMarketController} from "@secured-finance/interfaces/ILendingMarketController.sol";
import {ILendingMarket} from "@secured-finance/interfaces/ILendingMarket.sol";
import {ITokenVault} from "@secured-finance/interfaces/ITokenVault.sol";

interface IStrategyInterface is IStrategy {
    function BASIS_POINTS() external view returns (uint256);
    function currency() external view returns (bytes32);
    function getTargetMaturities() external view returns (uint256[] memory);

    function lendingMarketController()
        external
        view
        returns (ILendingMarketController);
    function tokenVault() external view returns (ITokenVault);
    function lendingMarket() external view returns (ILendingMarket);
}
