// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import "../src/GradualLiquidator.sol";
import "../src/interfaces/IGradualLiquidator.sol";
import "../src/interfaces/ICircleUSDCVault.sol";
import "../src/interfaces/IMEVDetector.sol";

// Mock contracts for testing
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

contract MockCircleUSDCVault is ICircleUSDCVault {
    MockERC20 public usdcToken;
    mapping(address => UserPosition) public userPositions;
    mapping(address => bool) public liquidatablePositions;
    address public shieldFiHook;
    
    constructor(address _usdcToken) {
        usdcToken = MockERC20(_usdcToken);
    }
    
    function setShieldFiHook(address _hook) external {
        shieldFiHook = _hook;
    }
    
    function getUserPosition(address user) external view returns (UserPosition memory) {
        return userPositions[user];
    }
    
    function isPositionLiquidatable(address user) external view returns (bool liquidatable, uint256 healthFactor) {
        liquidatable = liquidatablePositions[user];
        healthFactor = userPositions[user].healthFactor;
        return (liquidatable, healthFactor);
    }
    
    function getHealthFactor(address user) external view returns (uint256) {
        return userPositions[user].healthFactor;
    }
    
    function liquidate(address borrower, uint256 amount, address collateralAsset) external {
        require(liquidatablePositions[borrower], "Position not liquidatable");
        userPositions[borrower].borrowedAmount -= amount;
        // Simulate liquidation by transferring collateral
    }
    
    function emergencyLiquidate(address borrower, uint256 amount) external {
        userPositions[borrower].borrowedAmount -= amount;
    }
    
    // Helper functions for testing
    function setUserPosition(address user, UserPosition memory position) external {
        userPositions[user] = position;
    }
    
    function setLiquidatable(address user, bool liquidatable) external {
        liquidatablePositions[user] = liquidatable;
    }
    
    // Required functions from interface
    function deposit(uint256 amount) external {}
    function withdraw(uint256 amount) external {}
    function borrow(uint256 amount) external {}
    function repay(uint256 amount) external {}
    function depositCollateral(address asset, uint256 amount) external {}
    function withdrawCollateral(address asset, uint256 amount) external {}
    function updatePositionTracking(address, PoolKey calldata, ModifyLiquidityParams calldata) external {}
    function calculateHealthFactor(address user) external view returns (uint256) {
        return userPositions[user].healthFactor;
    }
    function getCollateralValue(address user) external view returns (uint256) {
        return userPositions[user].collateralValue;
    }
    function getBorrowedAmount(address user) external view returns (uint256) {
        return userPositions[user].borrowedAmount;
    }
    function addCollateralAsset(address, uint256, uint256, uint256, address) external {}
    function removeCollateralAsset(address) external {}
    function getLendingPool() external view returns (LendingPool memory) {
        return LendingPool({
            totalDeposits: 1000000e6,
            totalBorrows: 500000e6,
            utilizationRate: 5000,
            borrowRate: 500,
            supplyRate: 300,
            reserveFactor: 1000,
            lastUpdateTime: block.timestamp
        });
    }
    function updateInterestRates() external {}
    function accrueInterest() external {}
    function calculateLiquidation(address) external view returns (LiquidationData memory) {
        return LiquidationData({
            borrower: address(0),
            debtAmount: 0,
            collateralAmount: 0,
            collateralAsset: address(0),
            liquidationPenalty: 0,
            timestamp: block.timestamp
        });
    }
    function getCollateralAsset(address) external pure returns (CollateralAsset memory) {
        return CollateralAsset({
            tokenAddress: address(0),
            collateralFactor: 8000,
            liquidationThreshold: 8500,
            liquidationPenalty: 500,
            isActive: true,
            priceOracle: address(0)
        });
    }
    function getMaxBorrowAmount(address) external pure returns (uint256) {
        return 5000e6;
    }
    function getMaxWithdrawAmount(address, address) external pure returns (uint256) {
        return 1000e6;
    }
    function calculateAccruedInterest(address) external pure returns (uint256, uint256) {
        return (100e6, 50e6);
    }
    function getTotalValueLocked() external pure returns (uint256) {
        return 1000000e6;
    }
    function pauseLending() external {}
    function resumeLending() external {}
    function isLendingPaused() external pure returns (bool) {
        return false;
    }
    function updateCollateralAsset(address, uint256, uint256, uint256) external {}
    function getUtilizationStats() external pure returns (uint256, uint256, uint256) {
        return (5000, 500000e6, 1000000e6);
    }
    function getSupportedCollateralAssets() external pure returns (address[] memory) {
        address[] memory assets = new address[](0);
        return assets;
    }
}

contract MockMEVDetector is IMEVDetector {
    mapping(address => bool) public shouldFlagMEV;
    
    function flagLiquidation(address borrower, uint256, uint256) external view returns (bool) {
        return shouldFlagMEV[borrower];
    }
    
    function detectMEV(address sender, PoolKey calldata, SwapParams calldata) external view returns (bool isMEVAttempt, uint256 riskLevel) {
        isMEVAttempt = shouldFlagMEV[sender];
        riskLevel = shouldFlagMEV[sender] ? 80 : 20;
        return (isMEVAttempt, riskLevel);
    }
    
    function analyzePattern(address sender) external view returns (TransactionPattern memory pattern) {
        pattern = TransactionPattern({
            sender: sender,
            frequency: 1,
            averageSize: 1000e6,
            lastBlockSeen: block.number,
            flaggedBefore: shouldFlagMEV[sender]
        });
    }
    
    function getDetailedAnalysis(address sender, PoolKey calldata, SwapParams calldata) external view returns (MEVAnalysis memory analysis) {
        analysis = MEVAnalysis({
            isMEVAttempt: shouldFlagMEV[sender],
            riskLevel: shouldFlagMEV[sender] ? 80 : 20,
            confidence: 95,
            detectionReason: shouldFlagMEV[sender] ? "High frequency trading detected" : "Normal activity",
            timestamp: block.timestamp
        });
    }
    
    function updateThresholds(uint256, uint256, uint256) external {}
    
    function getStatistics() external pure returns (uint256 totalAnalyzed, uint256 totalFlagged, uint256 falsePositiveRate) {
        return (1000, 50, 500); // Mock data
    }
    
    function isWhitelisted(address) external pure returns (bool) {
        return false;
    }
    
    function addToWhitelist(address) external {}
    
    function removeFromWhitelist(address) external {}
    
    function setShouldFlagMEV(address user, bool flag) external {
        shouldFlagMEV[user] = flag;
    }
}

contract GradualLiquidatorTest is Test {
    GradualLiquidator public liquidator;
    MockCircleUSDCVault public vault;
    MockMEVDetector public mevDetector;
    MockERC20 public usdc;
    
    address public owner = address(this);
    address public shieldFiHook = makeAddr("shieldFiHook");
    address public liquidatorBot = makeAddr("liquidatorBot");
    address public borrower = makeAddr("borrower");
    address public otherUser = makeAddr("otherUser");
    
    bytes32 public testLiquidationId;
    
    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        
        // Deploy mock contracts
        mevDetector = new MockMEVDetector();
        vault = new MockCircleUSDCVault(address(usdc));
        
        // Deploy GradualLiquidator
        liquidator = new GradualLiquidator(
            address(vault),
            address(mevDetector),
            address(usdc)
        );
        
        // Set up integrations
        liquidator.setShieldFiHook(shieldFiHook);
        liquidator.setAuthorizedLiquidator(liquidatorBot, true);
        
        // Set up test borrower position
        ICircleUSDCVault.UserPosition memory position = ICircleUSDCVault.UserPosition({
            depositedAmount: 10000e6,
            borrowedAmount: 8000e6,
            collateralValue: 12000e6, // $12,000 worth of collateral
            healthFactor: 103, // Slightly above liquidation threshold
            lastUpdateTime: block.timestamp,
            isLiquidatable: true
        });
        
        vault.setUserPosition(borrower, position);
        vault.setLiquidatable(borrower, true);
        
        // Mint tokens for testing
        usdc.mint(address(vault), 1000000e6);
    }
    
    // =============================================================
    //                        BASIC FUNCTIONALITY TESTS
    // =============================================================
    
    function testContractDeployment() public {
        assertEq(address(liquidator.vault()), address(vault));
        assertEq(address(liquidator.mevDetector()), address(mevDetector));
        assertEq(address(liquidator.usdcToken()), address(usdc));
        assertEq(liquidator.owner(), owner);
    }
    
    function testConfigurationUpdate() public {
        IGradualLiquidator.LiquidationConfig memory newConfig = IGradualLiquidator.LiquidationConfig({
            minChunkSize: 200e6,
            maxChunkSize: 5000e6,
            chunkDelay: 300,
            maxMarketImpact: 300,
            emergencyMode: true
        });
        
        liquidator.updateConfig(newConfig);
        
        IGradualLiquidator.LiquidationConfig memory retrievedConfig = liquidator.getConfig();
        assertEq(retrievedConfig.minChunkSize, newConfig.minChunkSize);
        assertEq(retrievedConfig.maxChunkSize, newConfig.maxChunkSize);
        assertEq(retrievedConfig.chunkDelay, newConfig.chunkDelay);
        assertEq(retrievedConfig.maxMarketImpact, newConfig.maxMarketImpact);
        assertEq(retrievedConfig.emergencyMode, newConfig.emergencyMode);
    }
    
    function testAuthorizedLiquidatorManagement() public {
        address newLiquidator = makeAddr("newLiquidator");
        
        // Initially not authorized
        assertFalse(liquidator.authorizedLiquidators(newLiquidator));
        
        // Authorize liquidator
        liquidator.setAuthorizedLiquidator(newLiquidator, true);
        assertTrue(liquidator.authorizedLiquidators(newLiquidator));
        
        // Deauthorize liquidator
        liquidator.setAuthorizedLiquidator(newLiquidator, false);
        assertFalse(liquidator.authorizedLiquidators(newLiquidator));
    }
    
    // =============================================================
    //                        LIQUIDATION WORKFLOW TESTS
    // =============================================================
    
    function testStartGradualLiquidation() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 5000e6, 5);
        
        // Check liquidation is active
        assertTrue(liquidator.activeLiquidations(liquidationId));
        
        // Check statistics updated
        assertEq(liquidator.totalLiquidationsStarted(), 1);
        
        // Get liquidation status
        (
            address returnedBorrower,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256 chunksRemaining,
            uint256 nextExecutionTime
        ) = liquidator.getLiquidationStatus(liquidationId);
        
        assertEq(returnedBorrower, borrower);
        assertEq(totalAmount, 5000e6);
        assertEq(executedAmount, 0);
        assertGt(chunksRemaining, 0);
        assertGt(nextExecutionTime, 0);
        
        testLiquidationId = liquidationId;
    }
    
    function testExecuteNextChunk() public {
        // First start a liquidation
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 3000e6, 3);
        
        // Execute first chunk
        vm.prank(liquidatorBot);
        (bool success, uint256 chunkAmount) = liquidator.executeNextChunk(liquidationId);
        
        assertTrue(success);
        assertGt(chunkAmount, 0);
        
        // Check statistics
        assertGt(liquidator.totalValueLiquidated(), 0);
    }
    
    function testChunkExecutionWithDelay() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 2000e6, 4);
        
        // Try to execute chunk immediately (should work for first chunk)
        vm.prank(liquidatorBot);
        (bool success1,) = liquidator.executeNextChunk(liquidationId);
        assertTrue(success1);
        
        // Try to execute next chunk immediately (should fail due to delay)
        vm.prank(liquidatorBot);
        (bool success2,) = liquidator.executeNextChunk(liquidationId);
        assertFalse(success2); // Should fail due to execution delay
        
        // Advance time and try again
        vm.warp(block.timestamp + 700); // Advance by more than chunk delay
        vm.prank(liquidatorBot);
        (bool success3,) = liquidator.executeNextChunk(liquidationId);
        assertTrue(success3);
    }
    
    function testCompleteLiquidation() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 1000e6, 2);
        
        uint256 initialCompleted = liquidator.totalLiquidationsCompleted();
        
        // Execute all chunks by advancing time
        for (uint256 i = 0; i < 2; i++) {
            vm.warp(block.timestamp + 700);
            vm.prank(liquidatorBot);
            liquidator.executeNextChunk(liquidationId);
        }
        
        // Check liquidation is completed
        assertFalse(liquidator.activeLiquidations(liquidationId));
        assertEq(liquidator.totalLiquidationsCompleted(), initialCompleted + 1);
    }
    
    // =============================================================
    //                        MEV PROTECTION TESTS
    // =============================================================
    
    function testMEVProtectionDelay() public {
        // Set MEV detection to flag this borrower
        mevDetector.setShouldFlagMEV(borrower, true);
        
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 2000e6, 3);
        
        // Try to execute chunk - should be delayed due to MEV
        vm.prank(liquidatorBot);
        (bool success, uint256 chunkAmount) = liquidator.executeNextChunk(liquidationId);
        
        // Should return false due to MEV protection
        assertFalse(success);
        assertEq(chunkAmount, 0);
    }
    
    function testMEVProtectionBypass() public {
        // Set MEV detection to flag this borrower
        mevDetector.setShouldFlagMEV(borrower, true);
        
        // Enable emergency mode to bypass MEV protection
        IGradualLiquidator.LiquidationConfig memory config = liquidator.getConfig();
        config.emergencyMode = true;
        liquidator.updateConfig(config);
        
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 2000e6, 3);
        
        // Execute chunk - should succeed despite MEV detection
        vm.prank(liquidatorBot);
        (bool success,) = liquidator.executeNextChunk(liquidationId);
        
        assertTrue(success);
    }
    
    // =============================================================
    //                        HEALTH FACTOR MONITORING TESTS
    // =============================================================
    
    function testHealthFactorMonitoring() public {
        (uint256 healthFactor, uint256 trend) = liquidator.monitorHealthFactor(borrower);
        
        assertEq(healthFactor, 103); // From setUp
        assertEq(trend, 0); // First check should be stable
        
        // Update position to simulate deteriorating health
        ICircleUSDCVault.UserPosition memory updatedPosition = vault.getUserPosition(borrower);
        updatedPosition.healthFactor = 95; // Much worse
        vault.setUserPosition(borrower, updatedPosition);
        
        (uint256 newHealthFactor, uint256 newTrend) = liquidator.monitorHealthFactor(borrower);
        
        assertEq(newHealthFactor, 95);
        assertEq(newTrend, 2); // Deteriorating
    }
    
    function testEmergencyLiquidationTrigger() public {
        // Set up position with critical health factor
        ICircleUSDCVault.UserPosition memory criticalPosition = vault.getUserPosition(borrower);
        criticalPosition.healthFactor = 101; // Critical
        vault.setUserPosition(borrower, criticalPosition);
        
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 3000e6, 4);
        
        // Execute chunk - should trigger emergency liquidation
        vm.prank(liquidatorBot);
        (bool success, uint256 chunkAmount) = liquidator.executeNextChunk(liquidationId);
        
        assertTrue(success);
        assertGt(chunkAmount, 0);
        
        // Liquidation should be completed due to emergency trigger
        assertFalse(liquidator.activeLiquidations(liquidationId));
    }
    
    // =============================================================
    //                        REWARDS SYSTEM TESTS
    // =============================================================
    
    function testLiquidationRewards() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 2000e6, 3);
        
        uint256 initialRewards = liquidator.getLiquidatorRewards(liquidatorBot);
        
        // Execute chunk
        vm.prank(liquidatorBot);
        liquidator.executeNextChunk(liquidationId);
        
        uint256 newRewards = liquidator.getLiquidatorRewards(liquidatorBot);
        assertGt(newRewards, initialRewards);
    }
    
    function testEarlyExecutionBonus() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 1000e6, 2);
        
        uint256 initialRewards = liquidator.getLiquidatorRewards(liquidatorBot);
        
        // Execute chunk early (before scheduled time)
        vm.prank(liquidatorBot);
        liquidator.executeNextChunk(liquidationId);
        
        uint256 rewardsAfterEarly = liquidator.getLiquidatorRewards(liquidatorBot);
        
        // Should get base reward + early execution bonus
        assertGt(rewardsAfterEarly - initialRewards, 0);
    }
    
    function testCompletionBonus() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 800e6, 2);
        
        uint256 initialRewards = liquidator.getLiquidatorRewards(liquidatorBot);
        
        // Execute all chunks
        vm.prank(liquidatorBot);
        liquidator.executeNextChunk(liquidationId);
        
        vm.warp(block.timestamp + 700);
        vm.prank(liquidatorBot);
        liquidator.executeNextChunk(liquidationId);
        
        uint256 finalRewards = liquidator.getLiquidatorRewards(liquidatorBot);
        
        // Should include completion bonus
        assertGt(finalRewards, initialRewards);
    }
    
    // =============================================================
    //                        EMERGENCY FUNCTIONS TESTS
    // =============================================================
    
    function testEmergencyLiquidation() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 3000e6, 4);
        
        // Trigger emergency liquidation
        vm.prank(shieldFiHook);
        liquidator.emergencyLiquidate(liquidationId, "Critical system risk");
        
        // Liquidation should be completed
        assertFalse(liquidator.activeLiquidations(liquidationId));
        assertEq(liquidator.totalLiquidationsCompleted(), 1);
    }
    
    function testPauseLiquidation() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 2000e6, 3);
        
        vm.prank(liquidatorBot);
        liquidator.pauseLiquidation(liquidationId, "Market volatility");
        
        // Should still be active but paused (implementation-specific)
        assertTrue(liquidator.activeLiquidations(liquidationId));
    }
    
    // =============================================================
    //                        ACCESS CONTROL TESTS
    // =============================================================
    
    function testUnauthorizedLiquidation() public {
        vm.prank(otherUser);
        vm.expectRevert("Not authorized liquidator");
        liquidator.liquidateGradually(borrower, 1000e6, 3);
    }
    
    function testUnauthorizedConfigUpdate() public {
        IGradualLiquidator.LiquidationConfig memory config = liquidator.getConfig();
        
        vm.prank(otherUser);
        vm.expectRevert();
        liquidator.updateConfig(config);
    }
    
    function testUnauthorizedEmergencyLiquidation() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 1000e6, 2);
        
        vm.prank(otherUser);
        vm.expectRevert("Only ShieldFi hook");
        liquidator.emergencyLiquidate(liquidationId, "Unauthorized");
    }
    
    // =============================================================
    //                        EDGE CASES AND VALIDATION TESTS
    // =============================================================
    
    function testInvalidLiquidationAmount() public {
        vm.prank(liquidatorBot);
        vm.expectRevert("Amount too small");
        liquidator.liquidateGradually(borrower, 50e6, 3); // Below minimum
    }
    
    function testInvalidChunkCount() public {
        vm.prank(liquidatorBot);
        vm.expectRevert("Invalid chunk count");
        liquidator.liquidateGradually(borrower, 1000e6, 0);
        
        vm.prank(liquidatorBot);
        vm.expectRevert("Invalid chunk count");
        liquidator.liquidateGradually(borrower, 1000e6, 60); // Above maximum
    }
    
    function testNonLiquidatablePosition() public {
        vault.setLiquidatable(borrower, false);
        
        vm.prank(liquidatorBot);
        vm.expectRevert("Position not liquidatable");
        liquidator.liquidateGradually(borrower, 1000e6, 3);
    }
    
    function testInvalidLiquidationId() public {
        bytes32 invalidId = keccak256("invalid");
        
        vm.prank(liquidatorBot);
        vm.expectRevert("Liquidation not active");
        liquidator.executeNextChunk(invalidId);
    }
    
    function testMarketImpactCalculation() public {
        uint256 impact1 = liquidator.calculateMarketImpact(1000e6, 100000e6);
        assertEq(impact1, 100); // 1% impact
        
        uint256 impact2 = liquidator.calculateMarketImpact(10000e6, 100000e6);
        assertEq(impact2, 1000); // 10% impact
        
        uint256 impact3 = liquidator.calculateMarketImpact(1000e6, 0);
        assertEq(impact3, 10000); // 100% impact (no liquidity)
    }
    
    function testOptimalChunkingCalculation() public {
        IGradualLiquidator.MarketConditions memory conditions = IGradualLiquidator.MarketConditions({
            volatility: 300,
            liquidity: 50000e6,
            priceImpact: 100,
            timestamp: block.timestamp
        });
        
        (uint256 chunks, uint256[] memory chunkSizes, uint256[] memory delays) = 
            liquidator.calculateOptimalChunking(5000e6, 110, conditions);
        
        assertGt(chunks, 0);
        assertEq(chunkSizes.length, chunks);
        assertEq(delays.length, chunks);
        
        // Verify total amount matches
        uint256 totalChunkAmount = 0;
        for (uint256 i = 0; i < chunkSizes.length; i++) {
            totalChunkAmount += chunkSizes[i];
        }
        assertEq(totalChunkAmount, 5000e6);
    }
    
    // =============================================================
    //                        GAS OPTIMIZATION TESTS
    // =============================================================
    
    function testGasOptimization() public {
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 2000e6, 3);
        
        (bool isOptimal, uint256 estimatedGas) = liquidator.checkGasOptimization(liquidationId);
        
        assertGt(estimatedGas, 0);
        // In most cases should be optimal unless chunks are excessive
    }
    
    function testStatisticsTracking() public {
        uint256 initialStarted = liquidator.totalLiquidationsStarted();
        uint256 initialCompleted = liquidator.totalLiquidationsCompleted();
        uint256 initialValue = liquidator.totalValueLiquidated();
        
        vm.prank(liquidatorBot);
        bytes32 liquidationId = liquidator.liquidateGradually(borrower, 1000e6, 2);
        
        assertEq(liquidator.totalLiquidationsStarted(), initialStarted + 1);
        
        // Execute chunks
        vm.prank(liquidatorBot);
        liquidator.executeNextChunk(liquidationId);
        
        assertGt(liquidator.totalValueLiquidated(), initialValue);
        
        vm.warp(block.timestamp + 700);
        vm.prank(liquidatorBot);
        liquidator.executeNextChunk(liquidationId);
        
        assertEq(liquidator.totalLiquidationsCompleted(), initialCompleted + 1);
    }
} 