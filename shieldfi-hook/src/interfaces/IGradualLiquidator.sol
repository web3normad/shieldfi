// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IGradualLiquidator
 * @notice Interface for gradual liquidation management
 * @dev Breaks large liquidations into smaller, less impactful chunks
 */
interface IGradualLiquidator {
    // =============================================================
    //                        STRUCTS
    // =============================================================

    struct LiquidationChunk {
        bytes32 liquidationId;
        address borrower;
        uint256 chunkAmount;
        uint256 chunkIndex;
        uint256 totalChunks;
        uint256 executionTime;
        bool executed;
        uint256 marketImpact;
    }

    struct LiquidationConfig {
        uint256 minChunkSize;        // Minimum chunk size in USD
        uint256 maxChunkSize;        // Maximum chunk size in USD
        uint256 chunkDelay;          // Time delay between chunks
        uint256 maxMarketImpact;     // Maximum allowed market impact (basis points)
        bool emergencyMode;          // Emergency liquidation bypass
    }

    struct MarketConditions {
        uint256 volatility;          // Current market volatility
        uint256 liquidity;           // Available liquidity
        uint256 priceImpact;         // Expected price impact
        uint256 timestamp;           // Last update timestamp
    }

    // =============================================================
    //                        EVENTS
    // =============================================================

    event LiquidationStarted(
        bytes32 indexed liquidationId,
        address indexed borrower,
        uint256 totalAmount,
        uint256 chunks
    );

    event ChunkExecuted(
        bytes32 indexed liquidationId,
        uint256 indexed chunkIndex,
        uint256 amount,
        uint256 marketImpact
    );

    event LiquidationCompleted(
        bytes32 indexed liquidationId,
        address indexed borrower,
        uint256 totalExecuted,
        uint256 totalMarketImpact
    );

    event EmergencyLiquidation(
        bytes32 indexed liquidationId,
        address indexed borrower,
        uint256 amount,
        string reason
    );

    event ConfigUpdated(
        uint256 minChunkSize,
        uint256 maxChunkSize,
        uint256 chunkDelay,
        uint256 maxMarketImpact
    );

    event HealthFactorUpdated(
        address indexed borrower,
        uint256 healthFactor,
        uint256 trend
    );

    event LiquidationReward(
        address indexed liquidator,
        bytes32 indexed liquidationId,
        uint256 chunkIndex,
        uint256 reward
    );

    event CompletionBonus(
        address indexed liquidator,
        bytes32 indexed liquidationId,
        uint256 bonus
    );

    event RewardsClaimed(
        address indexed liquidator,
        uint256 amount
    );

    // =============================================================
    //                        FUNCTIONS
    // =============================================================

    /**
     * @notice Start gradual liquidation process
     * @param borrower Address being liquidated
     * @param totalAmount Total amount to liquidate
     * @param maxChunks Maximum number of chunks to split into
     * @return liquidationId Unique identifier for this liquidation
     */
    function liquidateGradually(
        address borrower,
        uint256 totalAmount,
        uint256 maxChunks
    ) external returns (bytes32 liquidationId);

    /**
     * @notice Execute the next chunk in a gradual liquidation
     * @param liquidationId Liquidation identifier
     * @return success Whether the chunk was executed successfully
     * @return chunkAmount Amount liquidated in this chunk
     */
    function executeNextChunk(bytes32 liquidationId) 
        external 
        returns (bool success, uint256 chunkAmount);

    /**
     * @notice Calculate optimal chunking strategy
     * @param totalAmount Total liquidation amount
     * @param healthFactor Current health factor
     * @param marketConditions Current market conditions
     * @return chunks Number of optimal chunks
     * @return chunkSizes Array of individual chunk sizes
     * @return delays Array of delays between chunks
     */
    function calculateOptimalChunking(
        uint256 totalAmount,
        uint256 healthFactor,
        MarketConditions calldata marketConditions
    ) external view returns (
        uint256 chunks,
        uint256[] memory chunkSizes,
        uint256[] memory delays
    );

    /**
     * @notice Get liquidation status and progress
     * @param liquidationId Liquidation identifier
     * @return borrower Address being liquidated
     * @return totalAmount Total liquidation amount
     * @return executedAmount Amount already liquidated
     * @return chunksRemaining Number of chunks remaining
     * @return nextExecutionTime When next chunk can be executed
     */
    function getLiquidationStatus(bytes32 liquidationId) external view returns (
        address borrower,
        uint256 totalAmount,
        uint256 executedAmount,
        uint256 chunksRemaining,
        uint256 nextExecutionTime
    );

    /**
     * @notice Get details of a specific liquidation chunk
     * @param liquidationId Liquidation identifier
     * @param chunkIndex Index of the chunk
     * @return chunk Chunk details
     */
    function getChunkDetails(bytes32 liquidationId, uint256 chunkIndex) 
        external view returns (LiquidationChunk memory chunk);

    /**
     * @notice Calculate market impact for a given liquidation amount
     * @param amount Liquidation amount
     * @param poolLiquidity Available pool liquidity
     * @return marketImpact Expected market impact in basis points
     */
    function calculateMarketImpact(uint256 amount, uint256 poolLiquidity) 
        external view returns (uint256 marketImpact);

    /**
     * @notice Pause a gradual liquidation (emergency only)
     * @param liquidationId Liquidation identifier
     * @param reason Reason for pausing
     */
    function pauseLiquidation(bytes32 liquidationId, string calldata reason) external;

    /**
     * @notice Resume a paused liquidation
     * @param liquidationId Liquidation identifier
     */
    function resumeLiquidation(bytes32 liquidationId) external;

    /**
     * @notice Force immediate liquidation (emergency only)
     * @param liquidationId Liquidation identifier
     * @param reason Reason for emergency liquidation
     */
    function emergencyLiquidate(bytes32 liquidationId, string calldata reason) external;

    /**
     * @notice Update liquidation configuration (admin only)
     * @param config New liquidation configuration
     */
    function updateConfig(LiquidationConfig calldata config) external;

    /**
     * @notice Get current liquidation configuration
     * @return config Current configuration
     */
    function getConfig() external view returns (LiquidationConfig memory config);

    /**
     * @notice Get current market conditions
     * @return conditions Current market conditions
     */
    function getMarketConditions() external view returns (MarketConditions memory conditions);

    /**
     * @notice Check if liquidation can be executed now
     * @param liquidationId Liquidation identifier
     * @return canExecute Whether next chunk can be executed
     * @return reason Reason if execution is blocked
     */
    function canExecuteNext(bytes32 liquidationId) 
        external view returns (bool canExecute, string memory reason);

    /**
     * @notice Get total number of active liquidations
     * @return count Number of active liquidations
     */
    function getActiveLiquidationCount() external view returns (uint256 count);

    /**
     * @notice Get list of active liquidation IDs
     * @param offset Starting index
     * @param limit Maximum number to return
     * @return liquidationIds Array of active liquidation IDs
     */
    function getActiveLiquidations(uint256 offset, uint256 limit) 
        external view returns (bytes32[] memory liquidationIds);
} 