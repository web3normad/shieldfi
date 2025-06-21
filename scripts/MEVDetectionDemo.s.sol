// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MEVDetectionEngine} from "../src/MEVDetectionEngine.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "lib/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";

contract MEVDetectionDemo is Script {
    using MEVDetectionEngine for MEVDetectionEngine.DetectionState;

    MEVDetectionEngine.DetectionState detectionState;
    PoolId poolId;
    
    // Demo addresses
    address constant ATTACKER = 0x1234567890123456789012345678901234567890;
    address constant VICTIM = 0x0987654321098765432109876543210987654321;
    
    // Constants
    uint256 constant LARGE_SWAP_AMOUNT = 60_000e18; // Above $50k threshold
    uint256 constant NORMAL_SWAP_AMOUNT = 10_000e18; // Below threshold
    uint256 constant HIGH_GAS_PRICE = 200 gwei;
    uint256 constant NORMAL_GAS_PRICE = 50 gwei;

    function run() external {
        console.log("=== MEV Detection Engine Demo ===\n");
        
        // Initialize
        poolId = PoolId.wrap(keccak256("demo-pool"));
        MEVDetectionEngine.updateBaselineGasPrice(detectionState, NORMAL_GAS_PRICE);
        
        console.log("Initialized detection engine");
        console.log("Baseline gas price:", NORMAL_GAS_PRICE);
        console.log("");
        
        // Demo 1: Large Swap Detection
        demoLargeSwapDetection();
        
        // Demo 2: Gas Price Anomaly Detection
        demoGasPriceAnomaly();
        
        // Demo 3: Engine Health Metrics
        demoEngineMetrics();
        
        console.log("=== Demo Complete ===");
    }
    
    function demoLargeSwapDetection() internal {
        console.log("1. LARGE SWAP DETECTION");
        console.log("-----------------------");
        
        console.log("Executing large 60k swap (above $50k threshold)");
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(LARGE_SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        vm.txGasPrice(NORMAL_GAS_PRICE);
        MEVDetectionEngine.MEVDetection memory detection = MEVDetectionEngine.analyzeTransaction(
            detectionState,
            poolId,
            ATTACKER,
            params,
            BalanceDelta.wrap(int256(LARGE_SWAP_AMOUNT))
        );
        
        if (detection.isDetected) {
            console.log("[+] MEV DETECTED!");
            console.log("Type:", _mevTypeToString(detection.mevType));
            console.log("Risk Score:", detection.riskScore, "/ 10000");
            console.log("Confidence:", detection.confidence, "%");
        } else {
            console.log("[-] No MEV detected");
        }
        console.log("");
    }
    
    function demoGasPriceAnomaly() internal {
        console.log("2. GAS PRICE ANOMALY DETECTION");
        console.log("------------------------------");
        
        uint256 anomalousGasPrice = NORMAL_GAS_PRICE * 5; // 500% of baseline
        console.log("Executing swap with anomalous gas price:", anomalousGasPrice);
        console.log("Baseline gas price:", NORMAL_GAS_PRICE);
        console.log("Ratio:", (anomalousGasPrice * 100) / NORMAL_GAS_PRICE, "%");
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(NORMAL_SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        vm.txGasPrice(anomalousGasPrice);
        MEVDetectionEngine.MEVDetection memory detection = MEVDetectionEngine.analyzeTransaction(
            detectionState,
            poolId,
            ATTACKER,
            params,
            BalanceDelta.wrap(int256(NORMAL_SWAP_AMOUNT))
        );
        
        if (detection.isDetected) {
            console.log("[+] MEV DETECTED!");
            console.log("Type:", _mevTypeToString(detection.mevType));
            console.log("Risk Score:", detection.riskScore, "/ 10000");
            console.log("Confidence:", detection.confidence, "%");
        } else {
            console.log("[-] No MEV detected");
        }
        console.log("");
    }
    
    function demoEngineMetrics() internal {
        console.log("3. ENGINE HEALTH METRICS");
        console.log("------------------------");
        
        (
            uint256 totalDetections,
            uint256 falsePositives,
            uint256 accuracyRate,
            uint256 falsePositiveRate,
            uint32 lastGasUpdate
        ) = MEVDetectionEngine.getEngineHealthMetrics(detectionState);
        
        console.log("Total Detections:", totalDetections);
        console.log("False Positives:", falsePositives);
        console.log("Accuracy Rate:", accuracyRate, "basis points");
        console.log("False Positive Rate:", falsePositiveRate, "basis points");
        
        // Pool statistics
        (
            uint256 avgSwapSize,
            uint256 totalVolume24h,
            uint256 transactionCount,
            uint256 activeLiquidations,
            uint256 avgPriceImpact
        ) = MEVDetectionEngine.getPoolDetectionStats(detectionState, poolId);
        
        console.log("\nPool Statistics:");
        console.log("Average Swap Size:", avgSwapSize);
        console.log("24h Volume:", totalVolume24h);
        console.log("Transaction Count:", transactionCount);
        console.log("Active Liquidations:", activeLiquidations);
        console.log("Average Price Impact:", avgPriceImpact, "bp");
        console.log("");
    }
    
    function _mevTypeToString(MEVDetectionEngine.MEVType mevType) internal pure returns (string memory) {
        if (mevType == MEVDetectionEngine.MEVType.NONE) return "NONE";
        if (mevType == MEVDetectionEngine.MEVType.SANDWICH_ATTACK) return "SANDWICH_ATTACK";
        if (mevType == MEVDetectionEngine.MEVType.LIQUIDATION_SANDWICH) return "LIQUIDATION_SANDWICH";
        if (mevType == MEVDetectionEngine.MEVType.LARGE_SWAP_MANIPULATION) return "LARGE_SWAP_MANIPULATION";
        if (mevType == MEVDetectionEngine.MEVType.GAS_PRICE_MANIPULATION) return "GAS_PRICE_MANIPULATION";
        if (mevType == MEVDetectionEngine.MEVType.FRONT_RUNNING) return "FRONT_RUNNING";
        if (mevType == MEVDetectionEngine.MEVType.BACK_RUNNING) return "BACK_RUNNING";
        if (mevType == MEVDetectionEngine.MEVType.VOLUME_MANIPULATION) return "VOLUME_MANIPULATION";
        if (mevType == MEVDetectionEngine.MEVType.TIMING_MANIPULATION) return "TIMING_MANIPULATION";
        return "UNKNOWN";
    }
}
