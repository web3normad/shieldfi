// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/**
 * @title ICircleUSDCVault
 * @notice Interface for Circle USDC lending infrastructure
 * @dev Manages USDC deposits, withdrawals, lending/borrowing, and collateral
 */
interface ICircleUSDCVault {
    // =============================================================
    //                        STRUCTS
    // =============================================================

    struct UserPosition {
        uint256 depositedAmount;     // Total USDC deposited
        uint256 borrowedAmount;      // Total USDC borrowed
        uint256 collateralValue;     // USD value of collateral
        uint256 healthFactor;        // Current health factor (scaled by 100)
        uint256 lastUpdateTime;      // Last position update
        bool isLiquidatable;         // Whether position can be liquidated
    }

    struct CollateralAsset {
        address tokenAddress;        // Address of collateral token
        uint256 collateralFactor;    // Loan-to-value ratio (basis points)
        uint256 liquidationThreshold; // Liquidation threshold (basis points)
        uint256 liquidationPenalty;  // Liquidation penalty (basis points)
        bool isActive;               // Whether asset is accepted as collateral
        address priceOracle;         // Price oracle for this asset
    }

    struct LendingPool {
        uint256 totalDeposits;       // Total USDC deposited
        uint256 totalBorrows;        // Total USDC borrowed
        uint256 utilizationRate;     // Current utilization rate (basis points)
        uint256 borrowRate;          // Current borrow interest rate
        uint256 supplyRate;          // Current supply interest rate
        uint256 reserveFactor;       // Reserve factor (basis points)
        uint256 lastUpdateTime;      // Last rate update
    }

    struct LiquidationData {
        address borrower;
        uint256 debtAmount;
        uint256 collateralAmount;
        address collateralAsset;
        uint256 liquidationPenalty;
        uint256 timestamp;
    }

    // =============================================================
    //                        EVENTS
    // =============================================================

    event Deposit(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    event Withdraw(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    event Borrow(
        address indexed user,
        uint256 amount,
        uint256 healthFactor,
        uint256 timestamp
    );

    event Repay(
        address indexed user,
        uint256 amount,
        uint256 remainingDebt,
        uint256 timestamp
    );

    event CollateralDeposited(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 value
    );

    event CollateralWithdrawn(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 value
    );

    event Liquidation(
        address indexed borrower,
        address indexed liquidator,
        uint256 debtAmount,
        uint256 collateralAmount,
        address collateralAsset
    );

    event EmergencyLiquidation(
        address indexed borrower,
        uint256 amount,
        string reason
    );

    event HealthFactorUpdated(
        address indexed user,
        uint256 oldHealthFactor,
        uint256 newHealthFactor
    );

    event InterestRatesUpdated(
        uint256 borrowRate,
        uint256 supplyRate,
        uint256 utilizationRate
    );

    // =============================================================
    //                        FUNCTIONS
    // =============================================================

    /**
     * @notice Deposit USDC into the lending pool
     * @param amount Amount of USDC to deposit
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Withdraw USDC from the lending pool
     * @param amount Amount of USDC to withdraw
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Borrow USDC against collateral
     * @param amount Amount of USDC to borrow
     */
    function borrow(uint256 amount) external;

    /**
     * @notice Repay borrowed USDC
     * @param amount Amount of USDC to repay
     */
    function repay(uint256 amount) external;

    /**
     * @notice Deposit collateral asset
     * @param asset Address of collateral asset
     * @param amount Amount of collateral to deposit
     */
    function depositCollateral(address asset, uint256 amount) external;

    /**
     * @notice Withdraw collateral asset
     * @param asset Address of collateral asset
     * @param amount Amount of collateral to withdraw
     */
    function withdrawCollateral(address asset, uint256 amount) external;

    /**
     * @notice Liquidate an undercollateralized position
     * @param borrower Address of borrower to liquidate
     * @param debtAmount Amount of debt to repay
     * @param collateralAsset Collateral asset to seize
     */
    function liquidate(
        address borrower,
        uint256 debtAmount,
        address collateralAsset
    ) external;

    /**
     * @notice Emergency liquidation (bypasses normal checks)
     * @param borrower Address of borrower to liquidate
     * @param amount Amount to liquidate
     */
    function emergencyLiquidate(address borrower, uint256 amount) external;

    /**
     * @notice Update position tracking for liquidity changes
     * @param user User address
     * @param key Pool key
     * @param params Liquidity modification parameters
     */
    function updatePositionTracking(
        address user,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params
    ) external;

    /**
     * @notice Calculate user's health factor
     * @param user User address
     * @return healthFactor Current health factor (scaled by 100)
     */
    function getHealthFactor(address user) external view returns (uint256 healthFactor);

    /**
     * @notice Get user's position details
     * @param user User address
     * @return position User position data
     */
    function getUserPosition(address user) external view returns (UserPosition memory position);

    /**
     * @notice Get collateral asset configuration
     * @param asset Collateral asset address
     * @return collateral Collateral asset configuration
     */
    function getCollateralAsset(address asset) external view returns (CollateralAsset memory collateral);

    /**
     * @notice Get lending pool information
     * @return pool Current lending pool data
     */
    function getLendingPool() external view returns (LendingPool memory pool);

    /**
     * @notice Calculate liquidation data for a position
     * @param borrower Borrower address
     * @return liquidationData Liquidation calculation results
     */
    function calculateLiquidation(address borrower) external view returns (LiquidationData memory liquidationData);

    /**
     * @notice Check if a position is liquidatable
     * @param borrower Borrower address
     * @return isLiquidatable Whether position can be liquidated
     * @return healthFactor Current health factor
     */
    function isPositionLiquidatable(address borrower) external view returns (bool isLiquidatable, uint256 healthFactor);

    /**
     * @notice Get maximum borrowable amount for a user
     * @param user User address
     * @return maxBorrow Maximum USDC that can be borrowed
     */
    function getMaxBorrowAmount(address user) external view returns (uint256 maxBorrow);

    /**
     * @notice Get maximum withdrawable collateral amount
     * @param user User address
     * @param asset Collateral asset address
     * @return maxWithdraw Maximum collateral that can be withdrawn
     */
    function getMaxWithdrawAmount(address user, address asset) external view returns (uint256 maxWithdraw);

    /**
     * @notice Calculate interest accrued for a user
     * @param user User address
     * @return borrowInterest Accrued borrow interest
     * @return supplyInterest Accrued supply interest
     */
    function calculateAccruedInterest(address user) external view returns (uint256 borrowInterest, uint256 supplyInterest);

    /**
     * @notice Update interest rates based on utilization
     */
    function updateInterestRates() external;

    /**
     * @notice Add new collateral asset (admin only)
     * @param asset Asset address
     * @param collateralFactor Loan-to-value ratio
     * @param liquidationThreshold Liquidation threshold
     * @param liquidationPenalty Liquidation penalty
     * @param priceOracle Price oracle address
     */
    function addCollateralAsset(
        address asset,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationPenalty,
        address priceOracle
    ) external;

    /**
     * @notice Update collateral asset parameters (admin only)
     * @param asset Asset address
     * @param collateralFactor New loan-to-value ratio
     * @param liquidationThreshold New liquidation threshold
     * @param liquidationPenalty New liquidation penalty
     */
    function updateCollateralAsset(
        address asset,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationPenalty
    ) external;

    /**
     * @notice Pause lending operations (emergency)
     */
    function pauseLending() external;

    /**
     * @notice Resume lending operations
     */
    function resumeLending() external;

    /**
     * @notice Get total value locked in the vault
     * @return tvl Total value locked in USD
     */
    function getTotalValueLocked() external view returns (uint256 tvl);

    /**
     * @notice Get vault utilization statistics
     * @return totalDeposits Total USDC deposits
     * @return totalBorrows Total USDC borrows
     * @return utilizationRate Current utilization rate
     */
    function getUtilizationStats() external view returns (
        uint256 totalDeposits,
        uint256 totalBorrows,
        uint256 utilizationRate
    );

    /**
     * @notice Get list of supported collateral assets
     * @return assets Array of supported collateral asset addresses
     */
    function getSupportedCollateralAssets() external view returns (address[] memory assets);

    /**
     * @notice Check if lending operations are paused
     * @return paused Whether lending is currently paused
     */
    function isLendingPaused() external view returns (bool paused);
} 