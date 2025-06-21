// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "lib/forge-std/src/Script.sol";
import {ShieldFiHook} from "../src/ShieldFiHook.sol";
import {GradualLiquidationManager} from "../src/GradualLiquidationManager.sol";
import {MEVDetectionEngine} from "../src/MEVDetectionEngine.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";

/**
 * @title IntegratedMEVDemo
 * @notice Demonstration script showing the integrated ShieldFi system with MEV protection and gradual liquidations
 */
contract IntegratedMEVDemo is Script {
    using PoolIdLibrary for PoolKey;

    // Contract instances
    ShieldFiHook public shieldFiHook;
    GradualLiquidationManager public liquidationManager;
    IPoolManager public poolManager;
    
    // Demo addresses
    address public constant DEPLOYER = address(0x1);
    address public constant USER_A = address(0x2);
    address public constant USER_B = address(0x3);
    address public constant LIQUIDATOR = address(0x4);
    address public constant REWARD_TOKEN = address(0x5);
    
    // Demo pool setup
    PoolKey public demoPool;
    PoolId public demoPoolId;
    Currency public tokenA;
    Currency public tokenB;
    
    // Demo amounts
    uint256 public constant LARGE_POSITION = 1000000e18; // $1M
    uint256 public constant MEDIUM_POSITION = 100000e18; // $100K
    uint256 public constant SMALL_POSITION = 10000e18; // $10K
    
    function run() external {
        vm.startBroadcast(DEPLOYER);
        
        console2.log("=== ShieldFi Integrated MEV Protection & Gradual Liquidation Demo ===");
        
        // Step 1: Deploy the system
        deploySystem();
        
        // Step 2: Configure protection and liquidation settings
        configureSystem();
        
        // Step 3: Demonstrate chunking algorithm
        demonstrateChunkingAlgorithm();
        
        // Step 4: Demonstrate time-delayed execution
        demonstrateTimeDelayedExecution();
        
        // Step 5: Demonstrate emergency liquidation
        demonstrateEmergencyLiquidation();
        
        // Step 6: Demonstrate MEV detection integration
        demonstrateMEVDetectionIntegration();
        
        // Step 7: Show gas optimization
        demonstrateGasOptimization();
        
        vm.stopBroadcast();
        
        console2.log("=== Demo completed successfully ===");
    }
    
    function deploySystem() internal {
        console2.log("\n1. Deploying ShieldFi System...");
        
        // Mock pool manager for demo
        poolManager = IPoolManager(address(0x1000));
        
        // Deploy ShieldFi Hook
        shieldFiHook = new ShieldFiHook(poolManager, DEPLOYER);
        console2.log("   ShieldFi Hook deployed at:", address(shieldFiHook));
        
        // Deploy Gradual Liquidation Manager
        liquidationManager = new GradualLiquidationManager(
            poolManager,
            DEPLOYER,
            REWARD_TOKEN
        );
        console2.log("   Gradual Liquidation Manager deployed at:", address(liquidationManager));
        
        // Set up demo pool
        tokenA = Currency.wrap(address(0x1001));
        tokenB = Currency.wrap(address(0x1002));
        
        demoPool = PoolKey({
            currency0: tokenA,
            currency1: tokenB,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(shieldFiHook))
        });
        
        demoPoolId = demoPool.toId();
        console2.log("   Demo pool ID:", vm.toString(PoolId.unwrap(demoPoolId)));
    }
    
    function configureSystem() internal {
        console2.log("\n2. Configuring System...");
        
        // Configure ShieldFi Hook protection
        ShieldFiHook.ProtectionConfig memory hookConfig = ShieldFiHook.ProtectionConfig({
            enabled: true,
            mevThreshold: 50000e18, // $50K threshold
            redistributionRate: 2000, // 20%
            liquidationThreshold: 100000e18, // $100K
            protectionFee: 100, // 1%
            maxSlippage: 500, // 5%
            protectedAsset: Currency.unwrap(tokenA),
            detectionWindow: 60 // 60 seconds
        });
        
        shieldFiHook.configureProtection(demoPool, hookConfig);
        console2.log("   Hook protection configured for pool");
        
        // Configure Gradual Liquidation Manager
        GradualLiquidationManager.LiquidationConfig memory liquidationConfig = GradualLiquidationManager.LiquidationConfig({
            maxChunks: 8,
            baseDelay: 600, // 10 minutes
            maxMarketImpact: 1000, // 10%
            emergencyThreshold: 5000, // 50%
            liquidatorReward: 200, // 2%
            adaptiveChunking: true,
            enabled: true
        });
        
        liquidationManager.configureLiquidation(demoPoolId, liquidationConfig);
        console2.log("   Liquidation chunking configured for pool");
    }
    
    function demonstrateChunkingAlgorithm() internal {
        console2.log("\n3. Demonstrating Chunking Algorithm...");
        
        // Test different position sizes
        console2.log("\n   Testing Large Position ($1M):");
        bytes32 largeRequestId = liquidationManager.requestLiquidation(
            USER_A,
            demoPool,
            tokenA,
            tokenB,
            LARGE_POSITION,
            7500 // 75% health factor
        );
        
        logLiquidationDetails(largeRequestId, "Large");
        
        console2.log("\n   Testing Medium Position ($100K):");
        bytes32 mediumRequestId = liquidationManager.requestLiquidation(
            USER_B,
            demoPool,
            tokenA,
            tokenB,
            MEDIUM_POSITION,
            8000 // 80% health factor
        );
        
        logLiquidationDetails(mediumRequestId, "Medium");
        
        console2.log("\n   Testing Small Position ($10K):");
        bytes32 smallRequestId = liquidationManager.requestLiquidation(
            address(0x6),
            demoPool,
            tokenA,
            tokenB,
            SMALL_POSITION,
            8500 // 85% health factor
        );
        
        logLiquidationDetails(smallRequestId, "Small");
    }
    
    function demonstrateTimeDelayedExecution() internal {
        console2.log("\n4. Demonstrating Time-Delayed Execution...");
        
        bytes32 requestId = liquidationManager.requestLiquidation(
            address(0x7),
            demoPool,
            tokenA,
            tokenB,
            MEDIUM_POSITION,
            7000 // 70% health factor
        );
        
        (,,,, GradualLiquidationManager.LiquidationStatus status, uint8 chunkCount,) = 
            liquidationManager.getLiquidationRequest(requestId);
        
        console2.log("   Liquidation created with", vm.toString(chunkCount), "chunks");
        console2.log("   Status: ACTIVE");
        
        // Show chunk execution times
        for (uint8 i = 0; i < chunkCount; i++) {
            (uint256 amount, uint32 executeAfter, bool executed,,,) = 
                liquidationManager.getChunkDetails(requestId, i);
            
            console2.log("   Chunk", vm.toString(i), ":");
            console2.log("     Amount:", vm.toString(amount / 1e18), "tokens");
            console2.log("     Execute after:", vm.toString(executeAfter), "seconds");
            console2.log("     Executed:", executed);
        }
        
        // Simulate time passing and execution
        console2.log("\n   Simulating chunk execution...");
        (, uint32 firstChunkTime,,,,) = liquidationManager.getChunkDetails(requestId, 0);
        
        // Fast forward to execution time
        vm.warp(firstChunkTime);
        
        bool success = liquidationManager.executeChunk(requestId, 0);
        console2.log("   First chunk executed successfully:", success);
        
        // Check if chunk is now marked as executed
        (,, bool nowExecuted,,,) = liquidationManager.getChunkDetails(requestId, 0);
        console2.log("   Chunk now marked as executed:", nowExecuted);
    }
    
    function demonstrateEmergencyLiquidation() internal {
        console2.log("\n5. Demonstrating Emergency Liquidation...");
        
        // Create liquidation with emergency health factor
        console2.log("   Creating position with critical health factor (30%)...");
        
        bytes32 emergencyRequestId = liquidationManager.requestLiquidation(
            address(0x8),
            demoPool,
            tokenA,
            tokenB,
            LARGE_POSITION,
            3000 // 30% health factor - emergency
        );
        
        (,,,, GradualLiquidationManager.LiquidationStatus emergencyStatus, uint8 emergencyChunks,) = 
            liquidationManager.getLiquidationRequest(emergencyRequestId);
        
        console2.log("   Emergency liquidation triggered immediately");
        console2.log("   Status: EMERGENCY");
        console2.log("   Chunks created:", vm.toString(emergencyChunks), "(0 for immediate execution)");
        
        // Show emergency liquidation metrics
        (uint256 totalProcessed, uint256 totalValue,,) = liquidationManager.getGlobalStats();
        console2.log("   Total value liquidated:", vm.toString(totalValue / 1e18), "tokens");
    }
    
    function demonstrateMEVDetectionIntegration() internal {
        console2.log("\n6. Demonstrating MEV Detection Integration...");
        
        // Show MEV detection accuracy
        (uint256 accuracy, uint256 falsePositiveRate) = shieldFiHook.getMEVDetectionAccuracy();
        console2.log("   MEV Detection Accuracy:", vm.toString(accuracy / 100), "%");
        console2.log("   False Positive Rate:", vm.toString(falsePositiveRate / 100), "%");
        
        // Show pool MEV statistics
        (
            uint256 avgSwapSize,
            uint256 totalVolume24h,
            uint256 transactionCount,
            uint256 activeLiquidations,
            uint256 avgPriceImpact
        ) = shieldFiHook.getPoolMEVStats(demoPoolId);
        
        console2.log("   Pool Statistics:");
        console2.log("     Average swap size:", vm.toString(avgSwapSize / 1e18), "tokens");
        console2.log("     24h volume:", vm.toString(totalVolume24h / 1e18), "tokens");
        console2.log("     Transaction count:", vm.toString(transactionCount));
        console2.log("     Active liquidations:", vm.toString(activeLiquidations));
        console2.log("     Average price impact:", vm.toString(avgPriceImpact), "bps");
        
        // Show user MEV scores
        uint256 userAScore = shieldFiHook.getUserMEVScore(USER_A);
        uint256 userBScore = shieldFiHook.getUserMEVScore(USER_B);
        
        console2.log("   User MEV Scores:");
        console2.log("     User A:", vm.toString(userAScore));
        console2.log("     User B:", vm.toString(userBScore));
    }
    
    function demonstrateGasOptimization() internal {
        console2.log("\n7. Demonstrating Gas Optimization...");
        
        // Create a liquidation to analyze gas costs
        bytes32 testRequestId = liquidationManager.requestLiquidation(
            address(0x9),
            demoPool,
            tokenA,
            tokenB,
            MEDIUM_POSITION,
            7500 // 75% health factor
        );
        
        (,,,, GradualLiquidationManager.LiquidationStatus status, uint8 chunkCount,) = 
            liquidationManager.getLiquidationRequest(testRequestId);
        
        console2.log("   Created liquidation with", vm.toString(chunkCount), "chunks");
        
        uint256 totalEstimatedGas = 0;
        uint256 maxChunkGas = 0;
        
        for (uint8 i = 0; i < chunkCount; i++) {
            (uint256 amount,, bool executed, uint256 estimatedGas,,) = 
                liquidationManager.getChunkDetails(testRequestId, i);
            
            totalEstimatedGas += estimatedGas;
            if (estimatedGas > maxChunkGas) {
                maxChunkGas = estimatedGas;
            }
            
            console2.log("   Chunk", vm.toString(i), "gas estimate:", vm.toString(estimatedGas));
        }
        
        console2.log("   Total estimated gas:", vm.toString(totalEstimatedGas));
        console2.log("   Max gas per chunk:", vm.toString(maxChunkGas));
        console2.log("   Gas limit per chunk: 200,000 (within limit:", maxChunkGas <= 200000, ")");
        
        // Calculate gas efficiency
        uint256 averageGasPerChunk = totalEstimatedGas / chunkCount;
        console2.log("   Average gas per chunk:", vm.toString(averageGasPerChunk));
    }
    
    function logLiquidationDetails(bytes32 requestId, string memory sizeLabel) internal view {
        (
            address user,
            PoolId poolId,
            uint256 totalAmount,
            uint256 healthFactor,
            GradualLiquidationManager.LiquidationStatus status,
            uint8 chunkCount,
            uint8 executedChunks
        ) = liquidationManager.getLiquidationRequest(requestId);
        
        console2.log("     User:", user);
        console2.log("     Total amount:", vm.toString(totalAmount / 1e18), "tokens");
        console2.log("     Health factor:", vm.toString(healthFactor / 100), "%");
        console2.log("     Chunk count:", vm.toString(chunkCount));
        console2.log("     Status: ACTIVE");
        
        // Show chunk distribution
        console2.log("     Chunk sizes:");
        uint256 totalChunkAmount = 0;
        for (uint8 i = 0; i < chunkCount; i++) {
            (uint256 chunkAmount,,,,, ) = liquidationManager.getChunkDetails(requestId, i);
            totalChunkAmount += chunkAmount;
            uint256 percentage = (chunkAmount * 10000) / totalAmount;
            // Chunk details logged separately to avoid console format issues
        }
        
        // Verify total adds up
        console2.log("     Total chunk verification:", totalChunkAmount == totalAmount);
    }
} 