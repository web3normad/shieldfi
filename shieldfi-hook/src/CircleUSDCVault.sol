// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import "./interfaces/ICircleUSDCVault.sol";

/**
 * @title CircleUSDCVault
 * @notice Circle USDC lending infrastructure with collateral management
 * @dev Manages deposits, withdrawals, lending/borrowing, and health factor calculations
 */
contract CircleUSDCVault is ICircleUSDCVault, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                        STATE VARIABLES
    // =============================================================

    IERC20 public immutable usdcToken;
    
    // User positions
    mapping(address => UserPosition) public userPositions;
    mapping(address => mapping(address => uint256)) public userCollateralBalances; // user => asset => amount
    
    // Collateral assets
    mapping(address => CollateralAsset) public collateralAssets;
    address[] public supportedAssets;
    
    // Lending pool state
    LendingPool public lendingPool;
    
    // Interest rate model parameters
    uint256 public constant OPTIMAL_UTILIZATION = 8000; // 80% in basis points
    uint256 public constant BASE_RATE = 200;           // 2% base rate
    uint256 public constant SLOPE1 = 400;              // 4% slope before optimal
    uint256 public constant SLOPE2 = 6000;             // 60% slope after optimal
    uint256 public constant RESERVE_FACTOR = 1000;     // 10% reserve factor
    
    // Constants
    uint256 public constant HEALTH_FACTOR_SCALE = 100;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant LIQUIDATION_BONUS = 500; // 5% liquidation bonus
    
    // Access control
    address public shieldFiHook;
    mapping(address => bool) public authorizedLiquidators;
    
    // Emergency controls
    bool public emergencyMode;
    uint256 public lastInterestUpdate;

    // =============================================================
    //                        MODIFIERS
    // =============================================================

    modifier onlyShieldFiHook() {
        require(msg.sender == shieldFiHook, "Only ShieldFi hook");
        _;
    }

    modifier onlyAuthorizedLiquidator() {
        require(authorizedLiquidators[msg.sender] || msg.sender == owner(), "Not authorized liquidator");
        _;
    }

    modifier updateInterest() {
        _updateInterestRates();
        _;
    }

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(address _usdcToken) Ownable(msg.sender) {
        usdcToken = IERC20(_usdcToken);
        lastInterestUpdate = block.timestamp;
        
        // Initialize lending pool
        lendingPool = LendingPool({
            totalDeposits: 0,
            totalBorrows: 0,
            utilizationRate: 0,
            borrowRate: BASE_RATE,
            supplyRate: 0,
            reserveFactor: RESERVE_FACTOR,
            lastUpdateTime: block.timestamp
        });
    }

    // =============================================================
    //                        CORE LENDING FUNCTIONS
    // =============================================================

    function deposit(uint256 amount) external override nonReentrant whenNotPaused updateInterest {
        require(amount > 0, "Amount must be greater than 0");
        
        UserPosition storage position = userPositions[msg.sender];
        
        // Transfer USDC from user
        usdcToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user position
        position.depositedAmount += amount;
        position.lastUpdateTime = block.timestamp;
        
        // Update lending pool
        lendingPool.totalDeposits += amount;
        
        emit Deposit(msg.sender, amount, block.timestamp);
    }

    function withdraw(uint256 amount) external override nonReentrant whenNotPaused updateInterest {
        require(amount > 0, "Amount must be greater than 0");
        
        UserPosition storage position = userPositions[msg.sender];
        require(position.depositedAmount >= amount, "Insufficient deposit balance");
        
        // Check if withdrawal would make user's position unhealthy
        if (position.borrowedAmount > 0) {
            uint256 newHealthFactor = _calculateHealthFactorAfterWithdraw(msg.sender, amount);
            require(newHealthFactor >= 110, "Withdrawal would make position unhealthy");
        }
        
        // Update user position
        position.depositedAmount -= amount;
        position.lastUpdateTime = block.timestamp;
        
        // Update lending pool
        lendingPool.totalDeposits -= amount;
        
        // Transfer USDC to user
        usdcToken.safeTransfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, amount, block.timestamp);
    }

    function borrow(uint256 amount) external override nonReentrant whenNotPaused updateInterest {
        require(amount > 0, "Amount must be greater than 0");
        require(!emergencyMode, "Emergency mode active");
        
        UserPosition storage position = userPositions[msg.sender];
        
        // Check borrowing capacity
        uint256 maxBorrow = getMaxBorrowAmount(msg.sender);
        require(amount <= maxBorrow, "Insufficient collateral");
        
        // Update user position
        position.borrowedAmount += amount;
        position.lastUpdateTime = block.timestamp;
        
        // Update lending pool
        lendingPool.totalBorrows += amount;
        
        // Calculate new health factor
        uint256 healthFactor = getHealthFactor(msg.sender);
        position.healthFactor = healthFactor;
        position.isLiquidatable = healthFactor < 110;
        
        // Transfer USDC to user
        usdcToken.safeTransfer(msg.sender, amount);
        
        emit Borrow(msg.sender, amount, healthFactor, block.timestamp);
    }

    function repay(uint256 amount) external override nonReentrant whenNotPaused updateInterest {
        require(amount > 0, "Amount must be greater than 0");
        
        UserPosition storage position = userPositions[msg.sender];
        require(position.borrowedAmount > 0, "No debt to repay");
        
        // Calculate actual repay amount (can't repay more than owed)
        uint256 actualRepayAmount = amount > position.borrowedAmount ? position.borrowedAmount : amount;
        
        // Transfer USDC from user
        usdcToken.safeTransferFrom(msg.sender, address(this), actualRepayAmount);
        
        // Update user position
        position.borrowedAmount -= actualRepayAmount;
        position.lastUpdateTime = block.timestamp;
        
        // Update lending pool
        lendingPool.totalBorrows -= actualRepayAmount;
        
        // Update health factor
        uint256 healthFactor = getHealthFactor(msg.sender);
        position.healthFactor = healthFactor;
        position.isLiquidatable = healthFactor < 110;
        
        emit Repay(msg.sender, actualRepayAmount, position.borrowedAmount, block.timestamp);
    }

    // =============================================================
    //                        COLLATERAL FUNCTIONS
    // =============================================================

    function depositCollateral(address asset, uint256 amount) external override nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(collateralAssets[asset].isActive, "Asset not supported");
        
        // Transfer collateral from user
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user collateral balance
        userCollateralBalances[msg.sender][asset] += amount;
        
        // Update user position
        UserPosition storage position = userPositions[msg.sender];
        position.collateralValue += _getAssetValue(asset, amount);
        position.lastUpdateTime = block.timestamp;
        
        // Update health factor
        uint256 healthFactor = getHealthFactor(msg.sender);
        position.healthFactor = healthFactor;
        position.isLiquidatable = healthFactor < 110;
        
        emit CollateralDeposited(msg.sender, asset, amount, _getAssetValue(asset, amount));
    }

    function withdrawCollateral(address asset, uint256 amount) external override nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(userCollateralBalances[msg.sender][asset] >= amount, "Insufficient collateral balance");
        
        // Check if withdrawal would make position unhealthy
        if (userPositions[msg.sender].borrowedAmount > 0) {
            uint256 newHealthFactor = _calculateHealthFactorAfterCollateralWithdraw(msg.sender, asset, amount);
            require(newHealthFactor >= 110, "Withdrawal would make position unhealthy");
        }
        
        // Update user collateral balance
        userCollateralBalances[msg.sender][asset] -= amount;
        
        // Update user position
        UserPosition storage position = userPositions[msg.sender];
        position.collateralValue -= _getAssetValue(asset, amount);
        position.lastUpdateTime = block.timestamp;
        
        // Update health factor
        uint256 healthFactor = getHealthFactor(msg.sender);
        position.healthFactor = healthFactor;
        position.isLiquidatable = healthFactor < 110;
        
        // Transfer collateral to user
        IERC20(asset).safeTransfer(msg.sender, amount);
        
        emit CollateralWithdrawn(msg.sender, asset, amount, _getAssetValue(asset, amount));
    }

    // =============================================================
    //                        LIQUIDATION FUNCTIONS
    // =============================================================

    function liquidate(
        address borrower,
        uint256 debtAmount,
        address collateralAsset
    ) external override nonReentrant onlyAuthorizedLiquidator {
        UserPosition storage position = userPositions[borrower];
        require(position.borrowedAmount > 0, "No debt to liquidate");
        require(position.isLiquidatable || getHealthFactor(borrower) < 110, "Position not liquidatable");
        
        // Calculate liquidation amounts
        LiquidationData memory liquidationData = calculateLiquidation(borrower);
        require(debtAmount <= liquidationData.debtAmount, "Debt amount too high");
        
        uint256 collateralAmount = _calculateCollateralToSeize(debtAmount, collateralAsset);
        require(userCollateralBalances[borrower][collateralAsset] >= collateralAmount, "Insufficient collateral");
        
        // Transfer debt payment from liquidator
        usdcToken.safeTransferFrom(msg.sender, address(this), debtAmount);
        
        // Update borrower position
        position.borrowedAmount -= debtAmount;
        position.collateralValue -= _getAssetValue(collateralAsset, collateralAmount);
        userCollateralBalances[borrower][collateralAsset] -= collateralAmount;
        position.lastUpdateTime = block.timestamp;
        
        // Update lending pool
        lendingPool.totalBorrows -= debtAmount;
        
        // Transfer collateral to liquidator (with bonus)
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralAmount);
        
        // Update health factor
        uint256 healthFactor = getHealthFactor(borrower);
        position.healthFactor = healthFactor;
        position.isLiquidatable = healthFactor < 110;
        
        emit Liquidation(borrower, msg.sender, debtAmount, collateralAmount, collateralAsset);
    }

    function emergencyLiquidate(address borrower, uint256 amount) external override onlyShieldFiHook {
        UserPosition storage position = userPositions[borrower];
        require(position.borrowedAmount > 0, "No debt to liquidate");
        
        uint256 liquidationAmount = amount > position.borrowedAmount ? position.borrowedAmount : amount;
        
        // Force liquidation without collateral seizure (emergency only)
        position.borrowedAmount -= liquidationAmount;
        position.lastUpdateTime = block.timestamp;
        
        // Update lending pool
        lendingPool.totalBorrows -= liquidationAmount;
        
        // Update health factor
        uint256 healthFactor = getHealthFactor(borrower);
        position.healthFactor = healthFactor;
        position.isLiquidatable = healthFactor < 110;
        
        emit EmergencyLiquidation(borrower, liquidationAmount, "Emergency liquidation by ShieldFi");
    }

    // =============================================================
    //                        POSITION TRACKING
    // =============================================================

    function updatePositionTracking(
        address user,
        PoolKey calldata /* key */,
        ModifyLiquidityParams calldata params
    ) external override onlyShieldFiHook {
        UserPosition storage position = userPositions[user];
        
        // Update position based on liquidity changes
        // This is a simplified implementation - in production would track actual LP positions
        if (params.liquidityDelta > 0) {
            // Adding liquidity - treat as collateral
            position.collateralValue += uint256(int256(params.liquidityDelta)) / 1e12; // Convert to USD estimate
        } else if (params.liquidityDelta < 0) {
            // Removing liquidity
            uint256 removedValue = uint256(int256(-params.liquidityDelta)) / 1e12;
            if (position.collateralValue > removedValue) {
                position.collateralValue -= removedValue;
            } else {
                position.collateralValue = 0;
            }
        }
        
        position.lastUpdateTime = block.timestamp;
        
        // Update health factor
        uint256 healthFactor = getHealthFactor(user);
        position.healthFactor = healthFactor;
        position.isLiquidatable = healthFactor < 110;
        
        if (position.healthFactor != healthFactor) {
            emit HealthFactorUpdated(user, position.healthFactor, healthFactor);
        }
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    function getHealthFactor(address user) public view override returns (uint256 healthFactor) {
        UserPosition memory position = userPositions[user];
        
        if (position.borrowedAmount == 0) {
            return type(uint256).max; // No debt = infinite health factor
        }
        
        if (position.collateralValue == 0) {
            return 0; // No collateral = zero health factor
        }
        
        // Health Factor = (Collateral Value * Liquidation Threshold) / Borrowed Amount
        // Scaled by 100 for precision (e.g., 150 = 1.5)
        uint256 adjustedCollateralValue = _getAdjustedCollateralValue(user);
        healthFactor = (adjustedCollateralValue * HEALTH_FACTOR_SCALE) / position.borrowedAmount;
        
        return healthFactor;
    }

    function getUserPosition(address user) external view override returns (UserPosition memory position) {
        return userPositions[user];
    }

    function getCollateralAsset(address asset) external view override returns (CollateralAsset memory collateral) {
        return collateralAssets[asset];
    }

    function getLendingPool() external view override returns (LendingPool memory pool) {
        return lendingPool;
    }

    function calculateLiquidation(address borrower) public view override returns (LiquidationData memory liquidationData) {
        UserPosition memory position = userPositions[borrower];
        
        // Find the collateral asset with highest value
        address bestCollateralAsset = address(0);
        uint256 maxCollateralValue = 0;
        
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            uint256 balance = userCollateralBalances[borrower][asset];
            if (balance > 0) {
                uint256 value = _getAssetValue(asset, balance);
                if (value > maxCollateralValue) {
                    maxCollateralValue = value;
                    bestCollateralAsset = asset;
                }
            }
        }
        
        liquidationData = LiquidationData({
            borrower: borrower,
            debtAmount: position.borrowedAmount,
            collateralAmount: userCollateralBalances[borrower][bestCollateralAsset],
            collateralAsset: bestCollateralAsset,
            liquidationPenalty: LIQUIDATION_BONUS,
            timestamp: block.timestamp
        });
    }

    function isPositionLiquidatable(address borrower) external view override returns (bool isLiquidatable, uint256 healthFactor) {
        healthFactor = getHealthFactor(borrower);
        isLiquidatable = healthFactor < 110; // Below 1.1 health factor
    }

    function getMaxBorrowAmount(address user) public view override returns (uint256 maxBorrow) {
        uint256 adjustedCollateralValue = _getAdjustedCollateralValue(user);
        UserPosition memory position = userPositions[user];
        
        if (adjustedCollateralValue > position.borrowedAmount) {
            maxBorrow = adjustedCollateralValue - position.borrowedAmount;
        } else {
            maxBorrow = 0;
        }
    }

    function getMaxWithdrawAmount(address user, address asset) external view override returns (uint256 maxWithdraw) {
        UserPosition memory position = userPositions[user];
        uint256 currentBalance = userCollateralBalances[user][asset];
        
        if (position.borrowedAmount == 0) {
            return currentBalance; // No debt, can withdraw all
        }
        
        // Calculate how much collateral is needed to maintain health factor > 1.1
        uint256 requiredCollateralValue = (position.borrowedAmount * 110) / 100;
        uint256 currentCollateralValue = position.collateralValue;
        
        if (currentCollateralValue <= requiredCollateralValue) {
            return 0; // Cannot withdraw any
        }
        
        uint256 excessCollateralValue = currentCollateralValue - requiredCollateralValue;
        uint256 assetValue = _getAssetValue(asset, currentBalance);
        
        if (excessCollateralValue >= assetValue) {
            return currentBalance; // Can withdraw all of this asset
        } else {
            // Calculate partial withdrawal amount
            return (currentBalance * excessCollateralValue) / assetValue;
        }
    }

    function calculateAccruedInterest(address user) external view override returns (uint256 borrowInterest, uint256 supplyInterest) {
        UserPosition memory position = userPositions[user];
        uint256 timeElapsed = block.timestamp - position.lastUpdateTime;
        
        if (timeElapsed == 0) {
            return (0, 0);
        }
        
        // Simple interest calculation (in production would use compound interest)
        borrowInterest = (position.borrowedAmount * lendingPool.borrowRate * timeElapsed) / (365 days * BASIS_POINTS);
        supplyInterest = (position.depositedAmount * lendingPool.supplyRate * timeElapsed) / (365 days * BASIS_POINTS);
    }

    function getTotalValueLocked() external view override returns (uint256 tvl) {
        tvl = lendingPool.totalDeposits;
        
        // Add value of all collateral assets
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            uint256 balance = IERC20(asset).balanceOf(address(this));
            tvl += _getAssetValue(asset, balance);
        }
    }

    function getUtilizationStats() external view override returns (
        uint256 totalDeposits,
        uint256 totalBorrows,
        uint256 utilizationRate
    ) {
        totalDeposits = lendingPool.totalDeposits;
        totalBorrows = lendingPool.totalBorrows;
        utilizationRate = lendingPool.utilizationRate;
    }

    function getSupportedCollateralAssets() external view override returns (address[] memory assets) {
        return supportedAssets;
    }

    function isLendingPaused() external view override returns (bool) {
        return paused() || emergencyMode;
    }

    // =============================================================
    //                        INTERNAL FUNCTIONS
    // =============================================================

    function _updateInterestRates() internal {
        if (block.timestamp <= lastInterestUpdate) {
            return;
        }
        
        uint256 totalDeposits = lendingPool.totalDeposits;
        uint256 totalBorrows = lendingPool.totalBorrows;
        
        if (totalDeposits == 0) {
            lendingPool.utilizationRate = 0;
            lendingPool.borrowRate = BASE_RATE;
            lendingPool.supplyRate = 0;
        } else {
            // Calculate utilization rate
            uint256 utilizationRate = (totalBorrows * BASIS_POINTS) / totalDeposits;
            lendingPool.utilizationRate = utilizationRate;
            
            // Calculate borrow rate using kinked interest rate model
            uint256 borrowRate;
            if (utilizationRate <= OPTIMAL_UTILIZATION) {
                borrowRate = BASE_RATE + (utilizationRate * SLOPE1) / BASIS_POINTS;
            } else {
                uint256 excessUtilization = utilizationRate - OPTIMAL_UTILIZATION;
                borrowRate = BASE_RATE + SLOPE1 + (excessUtilization * SLOPE2) / BASIS_POINTS;
            }
            
            lendingPool.borrowRate = borrowRate;
            
            // Calculate supply rate
            uint256 supplyRate = (borrowRate * utilizationRate * (BASIS_POINTS - RESERVE_FACTOR)) / (BASIS_POINTS * BASIS_POINTS);
            lendingPool.supplyRate = supplyRate;
        }
        
        lendingPool.lastUpdateTime = block.timestamp;
        lastInterestUpdate = block.timestamp;
        
        emit InterestRatesUpdated(lendingPool.borrowRate, lendingPool.supplyRate, lendingPool.utilizationRate);
    }

    function _getAdjustedCollateralValue(address user) internal view returns (uint256 adjustedValue) {
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            uint256 balance = userCollateralBalances[user][asset];
            
            if (balance > 0) {
                CollateralAsset memory collateral = collateralAssets[asset];
                uint256 assetValue = _getAssetValue(asset, balance);
                adjustedValue += (assetValue * collateral.liquidationThreshold) / BASIS_POINTS;
            }
        }
    }

    function _getAssetValue(address asset, uint256 amount) internal view returns (uint256 value) {
        // Simplified price calculation - in production would use oracle
        if (asset == address(usdcToken)) {
            return amount; // 1:1 for USDC
        }
        
        // For other assets, assume $1000 per token (placeholder)
        return amount * 1000;
    }

    function _calculateHealthFactorAfterWithdraw(address user, uint256 withdrawAmount) internal view returns (uint256) {
        UserPosition memory position = userPositions[user];
        
        if (position.borrowedAmount == 0) {
            return type(uint256).max;
        }
        
        uint256 newDepositAmount = position.depositedAmount - withdrawAmount;
        uint256 adjustedCollateralValue = _getAdjustedCollateralValue(user);
        
        // Add deposit value to collateral (simplified)
        uint256 totalCollateralValue = adjustedCollateralValue + newDepositAmount;
        
        if (totalCollateralValue == 0) {
            return 0;
        }
        
        return (totalCollateralValue * HEALTH_FACTOR_SCALE) / position.borrowedAmount;
    }

    function _calculateHealthFactorAfterCollateralWithdraw(
        address user,
        address asset,
        uint256 amount
    ) internal view returns (uint256) {
        UserPosition memory position = userPositions[user];
        
        if (position.borrowedAmount == 0) {
            return type(uint256).max;
        }
        
        uint256 adjustedCollateralValue = _getAdjustedCollateralValue(user);
        CollateralAsset memory collateral = collateralAssets[asset];
        uint256 withdrawValue = (_getAssetValue(asset, amount) * collateral.liquidationThreshold) / BASIS_POINTS;
        
        if (adjustedCollateralValue <= withdrawValue) {
            return 0;
        }
        
        uint256 newCollateralValue = adjustedCollateralValue - withdrawValue;
        return (newCollateralValue * HEALTH_FACTOR_SCALE) / position.borrowedAmount;
    }

    function _calculateCollateralToSeize(uint256 debtAmount, address collateralAsset) internal view returns (uint256) {
        CollateralAsset memory collateral = collateralAssets[collateralAsset];
        uint256 collateralValue = _getAssetValue(collateralAsset, 1e18); // Price per token
        
        // Add liquidation bonus
        uint256 bonusAmount = (debtAmount * (BASIS_POINTS + collateral.liquidationPenalty)) / BASIS_POINTS;
        
        return (bonusAmount * 1e18) / collateralValue;
    }

    // =============================================================
    //                        ADMIN FUNCTIONS
    // =============================================================

    function addCollateralAsset(
        address asset,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationPenalty,
        address priceOracle
    ) external override onlyOwner {
        require(asset != address(0), "Invalid asset address");
        require(collateralFactor <= BASIS_POINTS, "Invalid collateral factor");
        require(liquidationThreshold <= BASIS_POINTS, "Invalid liquidation threshold");
        
        collateralAssets[asset] = CollateralAsset({
            tokenAddress: asset,
            collateralFactor: collateralFactor,
            liquidationThreshold: liquidationThreshold,
            liquidationPenalty: liquidationPenalty,
            isActive: true,
            priceOracle: priceOracle
        });
        
        // Add to supported assets if not already present
        bool exists = false;
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            if (supportedAssets[i] == asset) {
                exists = true;
                break;
            }
        }
        
        if (!exists) {
            supportedAssets.push(asset);
        }
    }

    function updateCollateralAsset(
        address asset,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationPenalty
    ) external override onlyOwner {
        require(collateralAssets[asset].isActive, "Asset not supported");
        
        CollateralAsset storage collateral = collateralAssets[asset];
        collateral.collateralFactor = collateralFactor;
        collateral.liquidationThreshold = liquidationThreshold;
        collateral.liquidationPenalty = liquidationPenalty;
    }

    function setShieldFiHook(address _shieldFiHook) external onlyOwner {
        shieldFiHook = _shieldFiHook;
    }

    function setAuthorizedLiquidator(address liquidator, bool authorized) external onlyOwner {
        authorizedLiquidators[liquidator] = authorized;
    }

    function setEmergencyMode(bool _emergencyMode) external onlyOwner {
        emergencyMode = _emergencyMode;
    }

    function pauseLending() external override onlyOwner {
        _pause();
    }

    function resumeLending() external override onlyOwner {
        _unpause();
    }

    function updateInterestRates() external override {
        _updateInterestRates();
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
} 