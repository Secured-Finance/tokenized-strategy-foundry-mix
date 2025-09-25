// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "../../Strategy.sol";
import {StrategyFactory} from "../../StrategyFactory.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";
import {ILendingMarketController} from "@secured-finance/interfaces/ILendingMarketController.sol";
import {ILendingMarket} from "@secured-finance/interfaces/ILendingMarket.sol";
import {ITokenVault} from "@secured-finance/interfaces/ITokenVault.sol";
import {ProtocolTypes} from "@secured-finance/types/ProtocolTypes.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;
    StrategyFactory public strategyFactory;

    ILendingMarketController public lendingMarketController;
    ITokenVault public tokenVault;
    ILendingMarket public lendingMarket;
    bytes32 public currency;

    mapping(string => address) public tokenAddrs;
    mapping(string => address) public contractAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;
    uint256 public SECONDS_PER_YEAR = 365 days;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e30;
    uint256 public minFuzzAmount = 10_000;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 minutes;

    function setUp() public virtual {
        _setTokenAddrs();
        _setContractAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["USDC"]);

        // Set decimals
        decimals = asset.decimals();

        strategyFactory = new StrategyFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();
        lendingMarketController = strategy.lendingMarketController();
        tokenVault = strategy.tokenVault();
        lendingMarket = strategy.lendingMarket();
        currency = strategy.currency();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        uint256[] memory allocationRatios = new uint256[](2);
        allocationRatios[0] = 4; // 40%
        allocationRatios[1] = 6; // 60%

        IStrategyInterface _strategy = IStrategyInterface(
            address(
                strategyFactory.newStrategy(
                    address(asset),
                    "Tokenized Strategy",
                    contractAddrs["LendingMarketController"],
                    contractAddrs["TokenVault"],
                    "USDC",
                    1e6, // 1 USDC
                    100, // minAPR 1%
                    allocationRatios
                )
            )
        );

        vm.prank(management);
        _strategy.acceptManagement();

        vm.prank(management);
        _strategy.setProfitMaxUnlockTime(profitMaxUnlockTime);

        return address(_strategy);
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = strategy.totalAssets();
        uint256 _balance = ERC20(strategy.asset()).balanceOf(address(strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function changeMarketPrice(
        uint256 _maturity,
        uint256 _priceIncrement
    ) public {
        uint256 amount = 1e9; // 1,000 USDC
        uint256 newUnitPrice = _getNewUnitPrice(_maturity, _priceIncrement);

        airdrop(asset, management, amount * 2);

        // Deposit
        vm.prank(management);
        asset.approve(address(tokenVault), amount * 2);
        vm.prank(management);
        tokenVault.deposit(currency, amount * 2);

        // Place a lend order
        vm.prank(management);
        lendingMarketController.executeOrder(
            currency,
            _maturity,
            ProtocolTypes.Side.LEND,
            amount,
            newUnitPrice
        );

        // Fill the order
        vm.prank(management);
        lendingMarketController.executeOrder(
            currency,
            _maturity,
            ProtocolTypes.Side.BORROW,
            amount,
            newUnitPrice
        );

        skip(1 minutes);
    }

    function placeLendOrderAtMarketUnitPrice(
        uint256 _maturity,
        uint256 _amount
    ) public {
        uint8 orderBookId = lendingMarketController.getOrderBookId(
            currency,
            _maturity
        );
        uint256 bestLendUnitPrice = lendingMarket.getBestLendUnitPrice(
            orderBookId
        );
        uint256 unitPrice = lendingMarket.getMarketUnitPrice(orderBookId);

        if (unitPrice == 0 || bestLendUnitPrice <= unitPrice) {
            unitPrice = bestLendUnitPrice - 1;
        }

        airdrop(asset, management, _amount);

        vm.prank(management);
        asset.approve(address(tokenVault), _amount);

        vm.prank(management);
        lendingMarketController.depositAndExecuteOrder(
            currency,
            _maturity,
            ProtocolTypes.Side.LEND,
            _amount,
            unitPrice
        );
    }

    function calculateMaxLossExpected(
        uint256 _maturity,
        uint256 _amount
    ) public view returns (uint256) {
        uint8 orderBookId = lendingMarketController.getOrderBookId(
            currency,
            _maturity
        );
        uint256 bestBorrowUnitPrice = lendingMarket.getBestBorrowUnitPrice(
            orderBookId
        );

        uint256 marketUnitPrice = lendingMarket.getMarketUnitPrice(orderBookId);

        if (marketUnitPrice < bestBorrowUnitPrice) {
            return 0;
        }

        return calculateOrderFeeAmount(_maturity, _amount);
    }

    function calculateOrderFeeAmount(
        uint256 _maturity,
        uint256 _amount
    ) public view returns (uint256 orderFeeAmount) {
        if (block.timestamp >= _maturity) return 0;

        uint256 orderFeeRate = strategy.lendingMarket().getOrderFeeRate();
        uint256 duration = _maturity - block.timestamp;

        // NOTE: The formula is:
        // actualRate = feeRate * (duration / SECONDS_IN_YEAR)
        // orderFeeAmount = amount * actualRate
        orderFeeAmount =
            (orderFeeRate * duration * _amount) /
            (SECONDS_PER_YEAR * MAX_BPS);
    }

    function _setTokenAddrs() internal {
        // Mainnet
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Sepolia
        // tokenAddrs["USDC"] = 0x2A4cf28227baB81e3880517Bb1f526cD29638cd6;
    }

    function _setContractAddrs() internal {
        // Mainnet
        contractAddrs[
            "LendingMarketController"
        ] = 0x35e9D8e0223A75E51a67aa731127C91Ea0779Fe2;
        contractAddrs[
            "TokenVault"
        ] = 0xB74749b2213916b1dA3b869E41c7c57f1db69393;

        // Sepolia
        // contractAddrs[
        //     "LendingMarketController"
        // ] = 0xBFFC9E7d6FAbBc5B154F39F3103783942853A053;
        // contractAddrs[
        //     "TokenVault"
        // ] = 0xa7A13c85296d5c6aebaeE99ee40761E2bB105f92;
    }

    function _getNewUnitPrice(
        uint256 _maturity,
        uint256 _priceIncrement
    ) internal view returns (uint256) {
        uint8 orderBookId = lendingMarketController.getOrderBookId(
            currency,
            _maturity
        );
        uint256 marketUnitPrice = lendingMarket.getMarketUnitPrice(orderBookId);
        uint256 bestBorrowUnitPrice = lendingMarket.getBestBorrowUnitPrice(
            orderBookId
        );

        uint256 newUnitPrice = marketUnitPrice + _priceIncrement;

        if (bestBorrowUnitPrice >= newUnitPrice) {
            newUnitPrice = bestBorrowUnitPrice + 1;
        }
        if (newUnitPrice > strategy.BASIS_POINTS()) {
            newUnitPrice = strategy.BASIS_POINTS();
        }

        return newUnitPrice;
    }
}
