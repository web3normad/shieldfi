// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IMEVDetector.sol";

/**
 * @title MEVDetector
 * @notice MEV detection engine for identifying sandwich attacks and MEV extraction
 * @dev Analyzes transaction patterns and flags suspicious behavior
 */
contract MEVDetector is IMEVDetector, Ownable, ReentrancyGuard {
    // =============================================================
    //                        STATE VARIABLES
    // =============================================================

    // Detection thresholds
    uint256 public sandwichThreshold = 500; // 5% price impact threshold
    uint256 public frequencyThreshold = 5;  // Max 5 transactions per block
    uint256 public sizeThreshold = 1000e6;  // Min $1000 USDC for analysis
    uint256 public timeWindowThreshold = 3; // 3 blocks for sandwich detection

    // Transaction tracking
    mapping(address => TransactionPattern) public userPatterns;
    mapping(address => bool) public whitelistedAddresses;
    mapping(bytes32 => MEVAnalysis) public analysisCache;

    // Statistics
    uint256 public totalAnalyzed;
    uint256 public totalFlagged;
    uint256 public falsePositiveCount;

    // Block-level tracking for sandwich detection
    mapping(uint256 => mapping(address => uint256)) public blockTransactionCount;
    mapping(uint256 => mapping(bytes32 => SwapData)) public blockSwapData;

    struct SwapData {
        address sender;
        uint256 amountIn;
        uint256 amountOut;
        bool zeroForOne;
        uint256 timestamp;
    }

    // =============================================================
    //                        EVENTS
    // =============================================================

    event SandwichAttackDetected(
        address indexed attacker,
        bytes32 indexed poolId,
        uint256 frontrunAmount,
        uint256 backrunAmount,
        uint256 profit
    );

    event HighFrequencyTrading(
        address indexed trader,
        uint256 transactionCount,
        uint256 blockNumber
    );

    event LargeTransactionFlagged(
        address indexed sender,
        uint256 amount,
        uint256 riskLevel
    );

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor() Ownable(msg.sender) {}

    // =============================================================
    //                        CORE FUNCTIONS
    // =============================================================

    function detectMEV(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params
    ) external override returns (bool isMEVAttempt, uint256 riskLevel) {
        totalAnalyzed++;

        // Skip analysis for whitelisted addresses
        if (whitelistedAddresses[sender]) {
            return (false, 0);
        }

        // Calculate transaction size
        uint256 transactionSize = params.amountSpecified < 0 
            ? uint256(-params.amountSpecified) 
            : uint256(params.amountSpecified);

        // Skip small transactions
        if (transactionSize < sizeThreshold) {
            return (false, 0);
        }

        // Update user pattern
        _updateUserPattern(sender, transactionSize);

        // Perform MEV analysis
        MEVAnalysis memory analysis = _performAnalysis(sender, key, params);
        
        // Cache analysis result
        bytes32 analysisKey = keccak256(abi.encode(sender, key, params, block.timestamp));
        analysisCache[analysisKey] = analysis;

        if (analysis.isMEVAttempt) {
            totalFlagged++;
            emit MEVDetected(sender, keccak256(abi.encode(key)), analysis.riskLevel, analysis.detectionReason);
        }

        return (analysis.isMEVAttempt, analysis.riskLevel);
    }

    function flagLiquidation(
        address borrower,
        uint256 amount,
        uint256 healthFactor
    ) external override returns (bool requiresProtection) {
        // Liquidations with health factor close to threshold are suspicious
        if (healthFactor > 105 && healthFactor < 115) { // Between 1.05 and 1.15
            return true;
        }

        // Large liquidations are more likely to be MEV targets
        if (amount > 10000e6) { // > $10,000
            return true;
        }

        // Check if borrower has been targeted recently
        TransactionPattern memory pattern = userPatterns[borrower];
        if (pattern.lastBlockSeen > 0 && block.number - pattern.lastBlockSeen < 10) {
            return true;
        }

        return false;
    }

    function _performAnalysis(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params
    ) internal returns (MEVAnalysis memory analysis) {
        analysis.timestamp = block.timestamp;
        
        uint256 riskScore = 0;
        string memory reason = "";

        // Check for sandwich attack patterns
        uint256 sandwichRisk = _detectSandwichAttack(sender, key, params);
        if (sandwichRisk > 0) {
            riskScore += sandwichRisk;
            reason = string.concat(reason, "Sandwich attack pattern; ");
        }

        // Check for high-frequency trading
        uint256 frequencyRisk = _detectHighFrequencyTrading(sender);
        if (frequencyRisk > 0) {
            riskScore += frequencyRisk;
            reason = string.concat(reason, "High frequency trading; ");
        }

        // Check for large transaction manipulation
        uint256 sizeRisk = _detectLargeTransactionManipulation(sender, params);
        if (sizeRisk > 0) {
            riskScore += sizeRisk;
            reason = string.concat(reason, "Large transaction manipulation; ");
        }

        // Check for timing-based attacks
        uint256 timingRisk = _detectTimingAttacks(sender);
        if (timingRisk > 0) {
            riskScore += timingRisk;
            reason = string.concat(reason, "Timing-based attack; ");
        }

        // Normalize risk score to 0-100
        riskScore = riskScore > 100 ? 100 : riskScore;

        analysis.isMEVAttempt = riskScore >= 70; // 70% threshold for MEV flagging
        analysis.riskLevel = riskScore;
        analysis.confidence = _calculateConfidence(riskScore);
        analysis.detectionReason = reason;

        return analysis;
    }

    function _detectSandwichAttack(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params
    ) internal returns (uint256 riskLevel) {
        bytes32 poolId = keccak256(abi.encode(key));
        uint256 currentBlock = block.number;
        
        // Store current swap data
        blockSwapData[currentBlock][poolId] = SwapData({
            sender: sender,
            amountIn: params.amountSpecified < 0 ? uint256(-params.amountSpecified) : 0,
            amountOut: params.amountSpecified > 0 ? uint256(params.amountSpecified) : 0,
            zeroForOne: params.zeroForOne,
            timestamp: block.timestamp
        });

        // Check previous blocks for potential frontrun
        for (uint256 i = 1; i <= timeWindowThreshold && i <= currentBlock; i++) {
            uint256 checkBlock = currentBlock - i;
            SwapData memory prevSwap = blockSwapData[checkBlock][poolId];
            
            if (prevSwap.sender == sender && prevSwap.timestamp > 0) {
                // Same sender, opposite direction - potential sandwich
                if (prevSwap.zeroForOne != params.zeroForOne) {
                    uint256 profit = _estimateSandwichProfit(prevSwap, params);
                    if (profit > 0) {
                        emit SandwichAttackDetected(sender, poolId, prevSwap.amountIn, 
                            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : 0, profit);
                        return 80; // High risk for sandwich attack
                    }
                }
            }
        }

        return 0;
    }

    function _detectHighFrequencyTrading(address sender) internal returns (uint256 riskLevel) {
        uint256 currentBlock = block.number;
        blockTransactionCount[currentBlock][sender]++;
        
        uint256 txCount = blockTransactionCount[currentBlock][sender];
        
        if (txCount > frequencyThreshold) {
            emit HighFrequencyTrading(sender, txCount, currentBlock);
            return 60; // Medium-high risk for HFT
        }
        
        // Check frequency across recent blocks
        uint256 recentTxCount = 0;
        for (uint256 i = 0; i < 5 && i <= currentBlock; i++) {
            recentTxCount += blockTransactionCount[currentBlock - i][sender];
        }
        
        if (recentTxCount > frequencyThreshold * 3) {
            return 40; // Medium risk for sustained HFT
        }
        
        return 0;
    }

    function _detectLargeTransactionManipulation(
        address sender,
        SwapParams calldata params
    ) internal returns (uint256 riskLevel) {
        uint256 transactionSize = params.amountSpecified < 0 
            ? uint256(-params.amountSpecified) 
            : uint256(params.amountSpecified);
            
        // Very large transactions (>$100k) get scrutiny
        if (transactionSize > 100000e6) {
            emit LargeTransactionFlagged(sender, transactionSize, 50);
            return 50;
        }
        
        // Check if this is unusually large for this sender
        TransactionPattern memory pattern = userPatterns[sender];
        if (pattern.averageSize > 0 && transactionSize > pattern.averageSize * 10) {
            return 30; // Unusual size for this sender
        }
        
        return 0;
    }

    function _detectTimingAttacks(address sender) internal view returns (uint256 riskLevel) {
        TransactionPattern memory pattern = userPatterns[sender];
        
        // Transactions at block boundaries are suspicious
        if (block.timestamp % 12 < 2) { // Within 2 seconds of block time
            return 20;
        }
        
        // Very frequent transactions from same sender
        if (pattern.lastBlockSeen > 0 && block.number - pattern.lastBlockSeen == 1) {
            return 25; // Consecutive block transactions
        }
        
        return 0;
    }

    function _estimateSandwichProfit(
        SwapData memory frontrun,
        SwapParams calldata backrun
    ) internal pure returns (uint256 profit) {
        // Simplified profit estimation
        // In production, this would use more sophisticated price impact calculations
        uint256 frontrunAmount = frontrun.amountIn;
        uint256 backrunAmount = backrun.amountSpecified < 0 ? uint256(-backrun.amountSpecified) : 0;
        
        if (frontrunAmount > 0 && backrunAmount > 0) {
            // Estimate 0.1% profit on sandwich amount
            return (frontrunAmount * 10) / 10000;
        }
        
        return 0;
    }

    function _calculateConfidence(uint256 riskScore) internal pure returns (uint256 confidence) {
        // Higher risk scores have higher confidence
        if (riskScore >= 80) return 90;
        if (riskScore >= 60) return 75;
        if (riskScore >= 40) return 60;
        if (riskScore >= 20) return 45;
        return 30;
    }

    function _updateUserPattern(address sender, uint256 transactionSize) internal {
        TransactionPattern storage pattern = userPatterns[sender];
        
        if (pattern.sender == address(0)) {
            // First transaction for this sender
            pattern.sender = sender;
            pattern.frequency = 1;
            pattern.averageSize = transactionSize;
            pattern.lastBlockSeen = block.number;
            pattern.flaggedBefore = false;
        } else {
            // Update existing pattern
            if (pattern.lastBlockSeen == block.number) {
                pattern.frequency++;
            } else {
                pattern.frequency = 1;
            }
            
            // Update average size (simple moving average)
            pattern.averageSize = (pattern.averageSize + transactionSize) / 2;
            pattern.lastBlockSeen = block.number;
        }

        emit PatternUpdated(sender, pattern.frequency, pattern.averageSize);
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    function analyzePattern(address sender) external view override returns (TransactionPattern memory pattern) {
        return userPatterns[sender];
    }

    function getDetailedAnalysis(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params
    ) external view override returns (MEVAnalysis memory analysis) {
        bytes32 analysisKey = keccak256(abi.encode(sender, key, params, block.timestamp));
        return analysisCache[analysisKey];
    }

    function getStatistics() external view override returns (
        uint256 totalAnalyzedCount,
        uint256 totalFlaggedCount,
        uint256 falsePositiveRate
    ) {
        uint256 fpRate = totalFlagged > 0 ? (falsePositiveCount * 10000) / totalFlagged : 0;
        return (totalAnalyzed, totalFlagged, fpRate);
    }

    function isWhitelisted(address sender) external view override returns (bool isWhitelistedAddress) {
        return whitelistedAddresses[sender];
    }

    // =============================================================
    //                        ADMIN FUNCTIONS
    // =============================================================

    function updateThresholds(
        uint256 _sandwichThreshold,
        uint256 _frequencyThreshold,
        uint256 _sizeThreshold
    ) external override onlyOwner {
        uint256 oldSandwich = sandwichThreshold;
        uint256 oldFrequency = frequencyThreshold;
        uint256 oldSize = sizeThreshold;

        sandwichThreshold = _sandwichThreshold;
        frequencyThreshold = _frequencyThreshold;
        sizeThreshold = _sizeThreshold;

        emit ThresholdUpdated("sandwich", oldSandwich, _sandwichThreshold);
        emit ThresholdUpdated("frequency", oldFrequency, _frequencyThreshold);
        emit ThresholdUpdated("size", oldSize, _sizeThreshold);
    }

    function addToWhitelist(address sender) external override onlyOwner {
        whitelistedAddresses[sender] = true;
    }

    function removeFromWhitelist(address sender) external override onlyOwner {
        whitelistedAddresses[sender] = false;
    }

    function reportFalsePositive(bytes32 analysisKey) external onlyOwner {
        if (analysisCache[analysisKey].isMEVAttempt) {
            falsePositiveCount++;
            analysisCache[analysisKey].isMEVAttempt = false;
        }
    }

    function setTimeWindowThreshold(uint256 _timeWindowThreshold) external onlyOwner {
        timeWindowThreshold = _timeWindowThreshold;
    }
} 