// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/**
 * @title IMEVDetector
 * @notice Interface for MEV detection engine
 * @dev Monitors transaction patterns for sandwich attacks and abnormal liquidation attempts
 */
interface IMEVDetector {
    // =============================================================
    //                        STRUCTS
    // =============================================================

    struct MEVAnalysis {
        bool isMEVAttempt;
        uint256 riskLevel;        // 0-100 risk score
        uint256 confidence;       // 0-100 confidence level
        string detectionReason;   // Human readable reason
        uint256 timestamp;
    }

    struct TransactionPattern {
        address sender;
        uint256 frequency;        // Transactions per block
        uint256 averageSize;      // Average transaction size
        uint256 lastBlockSeen;    // Last block this sender was active
        bool flaggedBefore;       // Previously flagged for MEV
    }

    // =============================================================
    //                        EVENTS
    // =============================================================

    event MEVDetected(
        address indexed sender,
        bytes32 indexed poolId,
        uint256 riskLevel,
        string reason
    );

    event PatternUpdated(
        address indexed sender,
        uint256 frequency,
        uint256 averageSize
    );

    event ThresholdUpdated(
        string parameter,
        uint256 oldValue,
        uint256 newValue
    );

    // =============================================================
    //                        FUNCTIONS
    // =============================================================

    /**
     * @notice Detect MEV attempts in swap transactions
     * @param sender Address initiating the swap
     * @param key Pool key for the swap
     * @param params Swap parameters
     * @return isMEVAttempt Whether this appears to be MEV extraction
     * @return riskLevel Risk level from 0-100
     */
    function detectMEV(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params
    ) external returns (bool isMEVAttempt, uint256 riskLevel);

    /**
     * @notice Flag a liquidation for MEV protection analysis
     * @param borrower Address being liquidated
     * @param amount Liquidation amount
     * @param healthFactor Current health factor
     * @return requiresProtection Whether gradual liquidation should be applied
     */
    function flagLiquidation(
        address borrower,
        uint256 amount,
        uint256 healthFactor
    ) external returns (bool requiresProtection);

    /**
     * @notice Analyze transaction patterns for a specific address
     * @param sender Address to analyze
     * @return pattern Current transaction pattern data
     */
    function analyzePattern(address sender) external view returns (TransactionPattern memory pattern);

    /**
     * @notice Get detailed MEV analysis for a transaction
     * @param sender Transaction sender
     * @param key Pool key
     * @param params Swap parameters
     * @return analysis Detailed MEV analysis
     */
    function getDetailedAnalysis(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params
    ) external view returns (MEVAnalysis memory analysis);

    /**
     * @notice Update detection thresholds (admin only)
     * @param sandwichThreshold Threshold for sandwich attack detection
     * @param frequencyThreshold Maximum transaction frequency before flagging
     * @param sizeThreshold Minimum transaction size for analysis
     */
    function updateThresholds(
        uint256 sandwichThreshold,
        uint256 frequencyThreshold,
        uint256 sizeThreshold
    ) external;

    /**
     * @notice Get current detection statistics
     * @return totalAnalyzed Total transactions analyzed
     * @return totalFlagged Total transactions flagged as MEV
     * @return falsePositiveRate Current false positive rate (basis points)
     */
    function getStatistics() external view returns (
        uint256 totalAnalyzed,
        uint256 totalFlagged,
        uint256 falsePositiveRate
    );

    /**
     * @notice Check if an address is whitelisted (trusted)
     * @param sender Address to check
     * @return isWhitelisted Whether the address is whitelisted
     */
    function isWhitelisted(address sender) external view returns (bool isWhitelisted);

    /**
     * @notice Add address to whitelist (admin only)
     * @param sender Address to whitelist
     */
    function addToWhitelist(address sender) external;

    /**
     * @notice Remove address from whitelist (admin only)
     * @param sender Address to remove from whitelist
     */
    function removeFromWhitelist(address sender) external;
} 