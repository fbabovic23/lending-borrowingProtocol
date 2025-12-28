//SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.24;

import {LendingVault} from "./LendingVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract BorrowingPool {
    using SafeERC20 for IERC20;

    error BorrowingPool__NotAllowedTokenAsCollateral();
    error BorrowingPool__AmountIsZero();
    error BorrowingPool__HealthFactorIsBroken();
    error BorrowingPool__HealthFactorIsOk();
    error BorrowingPool__TokenAddressesAndPriceFeedsMustBeSameLength();

    LendingVault private immutable i_lv;

    uint256 private totalBorrows;
    uint256 private totalSupply;

    //To calculate users debt we are using formula
    // x*R(n-1)/R(k-1)
    uint256 private cumulativeRates = 1e18;
    //To see how much of debt user has, we need to call function calculateDebt(), not just use mapping debt
    mapping(address user => uint256) private debt;

    mapping(address user => mapping(address token => uint256 amount)) private userCollateralDeposited;
    mapping(address token => address priceFeed) private priceFeeds;
    address[] private collateralTokens;

    uint256 private lastUpdateTimestamp;

    uint256 constant LOAN_TO_VALUE = 70;
    uint256 constant LIQUIDATION_TRESHOLD = 80;
    uint256 constant LIQUIDATION_PRECISION = 100;
    uint256 constant MIN_HEALTH_FACTOR = 1e18;
    uint256 constant LIQUIDATION_BONUS = 10;

    uint256 constant OPTIMAL_UTILIZATION = 8e17;
    uint256 constant BASE_RATE = 2e16; //2%
    uint256 constant SLOPE1 = 4e16;
    uint256 constant SLOPE2 = 1e18;

    uint256 constant YEAR_SEC = 365 * 24 * 60 * 60 * 1e18;
    uint256 constant PRECISION = 1e18;

    event CollateralDeposited(address user, address collateralToken, uint256 amount);
    event CollateralRedeemed(address from, address to, address collateralToken, uint256 amountCollateral);
    event Borrowed(uint256 amount, address user);
    event Repaid(address repayer, address debtor, uint256 amount);

    modifier isCollateralAllowed(address token) {
        if (priceFeeds[token] == address(0)) {
            revert BorrowingPool__NotAllowedTokenAsCollateral();
        }
        _;
    }

    modifier moreThenZero(uint256 amount) {
        if (amount == 0) {
            revert BorrowingPool__AmountIsZero();
        }
        _;
    }

    constructor(address[] memory _collateralTokens, address[] memory _priceFeeds) {
        if (_collateralTokens.length != _priceFeeds.length) {
            revert BorrowingPool__TokenAddressesAndPriceFeedsMustBeSameLength();
        }
        i_lv = new LendingVault();

        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            collateralTokens.push(collateralTokens[i]);
            priceFeeds[collateralTokens[i]] = _priceFeeds[i];
        }
    }

    //////////////////////////////////////////////////////////
    ///////////////// external functions /////////////////////
    //////////////////////////////////////////////////////////
    function depositCollateral(address collateralToken, uint256 amount)
        public
        isCollateralAllowed(collateralToken)
        moreThenZero(amount)
    {
        userCollateralDeposited[msg.sender][collateralToken] += amount;

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, collateralToken, amount);
    }

    function depositCollateralAndBorrow(address collateralToken, uint256 amountCollateral, uint256 amountToBorrow)
        external
    {
        depositCollateral(collateralToken, amountCollateral);
        borrow(amountToBorrow);
    }

    function redeemCollaterall(address collateralToken, uint256 amountToRedeem)
        external
        moreThenZero(amountToRedeem)
        isCollateralAllowed(collateralToken)
    {
        _redeemCollaterall(collateralToken, amountToRedeem, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function borrow(uint256 amount) public moreThenZero(amount) {
        _updateCumulativeRates();

        debt[msg.sender] += Math.mulDiv(amount, 1e18, cumulativeRates);

        //Da li ovom mestu ili na samom kraju revert da ostavim?
        _revertIfHealthFactorIsBroken(msg.sender);

        i_lv.lend(msg.sender, amount);

        emit Borrowed(amount, msg.sender);

        _updateCumulativeRates();
        //_revertIfHealthFactorIsBroken(msg.sender);
    }

    function repay(uint256 amount) external moreThenZero(amount) {
        _repay(msg.sender, msg.sender, amount);
    }

    function liquidate(address debtor, address collateralToken, uint256 debtToCover)
        external
        moreThenZero(debtToCover)
    {
        if (_calculateHealthFactor(debtor) > MIN_HEALTH_FACTOR) {
            revert BorrowingPool__HealthFactorIsOk();
        }

        uint256 amountOfToken = _getTokenFromUsdValue(collateralToken, debtToCover);
        uint256 liqudationBonus = amountOfToken * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;

        _redeemCollaterall(collateralToken, amountOfToken + liqudationBonus, debtor, msg.sender);
        _repay(debtor, msg.sender, debtToCover);
    }

    function calculateHealthFactor(address user) external returns (uint256) {
        return _calculateHealthFactor(user);
    }

    function calculateDebt(address user) external returns (uint256) {
        return _calculateDebt(user);
    }

    function currentBorrowRate() external returns (uint256 borrowRate) {
        return _currentBorrowRate();
    }
    //////////////////////////////////////////////////////////
    ///////////////// public functions ///////////////////////
    //////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////
    ///////////////// internal functions /////////////////////
    //////////////////////////////////////////////////////////

    function _redeemCollaterall(address collateralToken, uint256 amountCollateral, address from, address to) internal {
        //PITANJE

        userCollateralDeposited[from][collateralToken] -= amountCollateral;
        IERC20(collateralToken).safeTransfer(to, amountCollateral);

        emit CollateralRedeemed(from, to, collateralToken, amountCollateral);
    }

    function _repay(address repayer, address debtor, uint256 amount) internal {
        uint256 amountToRepay = _calculateDebt(debtor);

        if (amount > amountToRepay) {
            //Je l ima smisla ovo da se uradi?
            amount = amountToRepay;
        }
        debt[debtor] -= Math.mulDiv(amount, 1e18, cumulativeRates);

        IERC20(i_lv.asset()).safeTransferFrom(repayer, address(i_lv), amount);

        emit Repaid(repayer, debtor, amount);

        _updateCumulativeRates();
    }

    function _getAccountInformation(address user)
        internal
        returns (uint256 totalBorrowed, uint256 collateralValueInUsd)
    {
        totalBorrowed = _calculateDebt(user);

        for (uint256 i = 0; i < collateralTokens.length; i++) {
            uint256 amountCollateral = userCollateralDeposited[user][collateralTokens[i]];
            collateralValueInUsd += _getUsdValue(collateralTokens[i], amountCollateral);
        }
    }

    function _revertIfHealthFactorIsBroken(address user) internal {
        uint256 healthFactor = _calculateHealthFactor(user);

        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert BorrowingPool__HealthFactorIsBroken();
        }
    }

    function _calculateHealthFactor(address user) internal returns (uint256) {
        (uint256 totalBorrowed, uint256 collateralValueInUsd) = _getAccountInformation(user);

        if (totalBorrowed == 0) {
            return type(uint256).max;
        }

        uint256 collateralValueAdjusted = collateralValueInUsd * LIQUIDATION_TRESHOLD / LIQUIDATION_PRECISION;

        return collateralValueAdjusted * PRECISION / totalBorrowed;
    }

    function _getUsdValue(address collateralToken, uint256 amount) internal view returns (uint256) {
        uint256 priceCollateralAdjusted = _getPriceFeed(collateralToken);

        return Math.mulDiv(priceCollateralAdjusted, amount, PRECISION);
    }

    function _getTokenFromUsdValue(address collateralToken, uint256 amount) internal view returns (uint256) {
        uint256 priceCollateralAdjusted = _getPriceFeed(collateralToken);

        return Math.mulDiv(amount, PRECISION, priceCollateralAdjusted);
    }

    function _getPriceFeed(address collateralToken) internal view returns (uint256 priceAdjusted) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeeds[collateralToken]);

        uint256 priceDecimals = uint256(priceFeed.decimals());
        uint256 precisionPriceFeed = 1e18 / (10 ** priceDecimals);

        (, int256 price,,,) = priceFeed.latestRoundData();

        priceAdjusted = Math.mulDiv(uint256(price), precisionPriceFeed, 1);
    }

    function _currentBorrowRate() internal returns (uint256 borrowRate) {
        _updateTotalSupply();

        uint256 utilization = totalBorrows / totalSupply;

        if (utilization > OPTIMAL_UTILIZATION) {
            borrowRate = BASE_RATE + SLOPE1 + SLOPE2 * ((utilization - OPTIMAL_UTILIZATION) / (1 - OPTIMAL_UTILIZATION));
        } else {
            borrowRate = BASE_RATE + SLOPE1 * (utilization / OPTIMAL_UTILIZATION);
        }
    }

    function _updateCumulativeRates() internal {
        uint256 dt = block.timestamp - lastUpdateTimestamp;

        uint256 borrowRate = _currentBorrowRate();

        uint256 interestRate = 1 + borrowRate * (dt / YEAR_SEC);

        cumulativeRates *= interestRate;

        lastUpdateTimestamp = block.timestamp;
    }

    function _calculateDebt(address user) internal returns (uint256) {
        _updateCumulativeRates();

        return debt[user] * cumulativeRates / 1e18;
    }

    function _updateTotalSupply() internal view {
        totalSupply = i_lv.totalAssets();
    }
}
