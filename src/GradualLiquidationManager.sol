// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title GradualLiquidationManager
 * @notice Manages gradual liquidations to minimize market impact and prevent MEV exploitation
 * @dev Breaks large liquidations into optimal chunks with time delays and market impact calculations
 * @author ShieldFi Protocol
 */
contract GradualLiquidationManager is Ownable, ReentrancyGuard, Pausable {
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============
    
    /// @notice Minimum chunks for any liquidation
    uint8 public constant MIN_CHUNKS = 3;
    
    /// @notice Maximum chunks for any liquidation
    uint8 public constant MAX_CHUNKS = 8;
    
    /// @notice Minimum delay between chunks (5 minutes)
    uint32 public constant MIN_CHUNK_DELAY = 300;
    
    /// @notice Maximum delay between chunks (1 hour)
    uint32 public constant MAX_CHUNK_DELAY = 3600;
    
    /// @notice Emergency liquidation health factor threshold (50%)
    uint256 public constant EMERGENCY_HEALTH_THRESHOLD = 5000; // 50% in basis points
    
    /// @notice Market impact threshold for emergency liquidation (5%)
    uint256 public constant EMERGENCY_IMPACT_THRESHOLD = 500; // 5% in basis points
    
    /// @notice Maximum gas per chunk operation
    uint256 public constant MAX_GAS_PER_CHUNK = 200000;

    // ============ Structs ============
    
    /// @notice Configuration for gradual liquidation
    struct LiquidationConfig {
        uint8 maxChunks;              // Maximum number of chunks (3-8)
        uint32 baseDelay;             // Base delay between chunks in seconds
        uint256 maxMarketImpact;      // Maximum allowed market impact per chunk (basis points)
        uint256 emergencyThreshold;   // Health factor threshold for emergency liquidation
        uint256 liquidatorReward;     // Reward per chunk (basis points)
        bool adaptiveChunking;        // Whether to use adaptive chunking based on market conditions
        bool enabled;                 // Whether gradual liquidation is enabled for this pool
    }
    
    /// @notice Individual liquidation chunk data
    struct LiquidationChunk {
        uint256 amount;               // Amount to liquidate in this chunk
        uint32 executeAfter;          // Timestamp after which chunk can be executed
        bool executed;                // Whether chunk has been executed
        uint256 estimatedGas;         // Estimated gas cost for this chunk
        uint256 marketImpact;         // Estimated market impact (basis points)
        address executor;             // Address that will execute this chunk
    }
    
    /// @notice Complete liquidation request
    struct LiquidationRequest {
        bytes32 requestId;            // Unique identifier for this liquidation
        address user;                 // User being liquidated
        PoolId poolId;                // Pool where liquidation occurs
        Currency collateralCurrency;  // Currency being liquidated
        Currency debtCurrency;        // Currency owed
        uint256 totalAmount;          // Total amount to liquidate
        uint256 healthFactor;         // Current health factor
        uint32 createdAt;             // When liquidation was requested
        uint32 lastChunkTime;         // When last chunk was executed
        LiquidationChunk[] chunks;    // Array of liquidation chunks
        LiquidationStatus status;     // Current status
        bool isEmergency;             // Whether this is an emergency liquidation
        uint256 totalRewardsPaid;     // Total rewards paid to liquidators
    }
    
    /// @notice Market conditions for adaptive chunking
    struct MarketConditions {
        uint256 volatility;           // Recent price volatility (basis points)
        uint256 liquidityDepth;       // Available liquidity in pool
        uint256 averageTradeSize;     // Average trade size in pool
        uint256 gasPrice;             // Current gas price
        uint32 lastUpdate;            // When conditions were last updated
    }
    
    /// @notice Liquidation queue entry
    struct QueueEntry {
        bytes32 requestId;            // Liquidation request ID
        uint8 priority;               // Priority level (0 = highest)
        uint32 nextExecutionTime;     // Next available execution time
        uint8 nextChunkIndex;         // Index of next chunk to execute
    }

    /// @notice Liquidation status enum
    enum LiquidationStatus {
        PENDING,         // Liquidation created, chunks not yet scheduled
        ACTIVE,          // Chunks are being executed gradually
        COMPLETED,       // All chunks executed successfully
        EMERGENCY,       // Switched to emergency liquidation
        CANCELLED        // Liquidation cancelled (health recovered)
    }

    // ============ Events ============
    
    event LiquidationRequested(
        bytes32 indexed requestId,
        address indexed user,
        PoolId indexed poolId,
        uint256 totalAmount,
        uint8 chunkCount,
        uint256 healthFactor
    );
    
    event ChunkExecuted(
        bytes32 indexed requestId,
        uint8 indexed chunkIndex,
        address indexed executor,
        uint256 amount,
        uint256 actualImpact,
        uint256 reward
    );
    
    event EmergencyLiquidationTriggered(
        bytes32 indexed requestId,
        address indexed user,
        uint256 remainingAmount,
        uint256 healthFactor
    );
    
    event LiquidationCompleted(
        bytes32 indexed requestId,
        address indexed user,
        uint256 totalLiquidated,
        uint256 totalRewards
    );
    
    event ChunkingConfigUpdated(
        PoolId indexed poolId,
        LiquidationConfig config
    );
    
    event MarketConditionsUpdated(
        PoolId indexed poolId,
        uint256 volatility,
        uint256 liquidityDepth
    );

    // ============ State Variables ============
    
    IPoolManager public immutable poolManager;
    
    /// @dev Pool-specific liquidation configurations
    mapping(PoolId => LiquidationConfig) public liquidationConfigs;
    
    /// @dev Active liquidation requests
    mapping(bytes32 => LiquidationRequest) public liquidationRequests;
    
    /// @dev Liquidation queue for execution scheduling
    QueueEntry[] public liquidationQueue;
    
    /// @dev Pool market conditions for adaptive chunking
    mapping(PoolId => MarketConditions) public marketConditions;
    
    /// @dev User liquidation history
    mapping(address => bytes32[]) public userLiquidations;
    
    /// @dev Liquidator performance tracking
    mapping(address => uint256) public liquidatorRewards;
    mapping(address => uint256) public liquidatorExecutions;
    
    /// @dev Global settings
    uint256 public globalLiquidatorReward = 150; // 1.5% default reward
    address public rewardToken;
    uint256 public totalLiquidationsProcessed;
    uint256 public totalValueLiquidated;
    
    /// @dev Emergency controls
    mapping(address => bool) public emergencyLiquidators;
    bool public emergencyMode;

    // ============ Constructor ============
    
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _rewardToken
    ) Ownable(_owner) {
        poolManager = _poolManager;
        rewardToken = _rewardToken;
        emergencyLiquidators[_owner] = true;
    }

    // ============ Main Liquidation Functions ============
    
    /**
     * @notice Request gradual liquidation for a position
     */
    function requestLiquidation(
        address user,
        PoolKey calldata poolKey,
        Currency collateralCurrency,
        Currency debtCurrency,
        uint256 amount,
        uint256 healthFactor
    ) external nonReentrant whenNotPaused returns (bytes32 requestId) {
        PoolId poolId = poolKey.toId();
        LiquidationConfig memory config = liquidationConfigs[poolId];
        
        require(config.enabled, "Gradual liquidation not enabled for pool");
        require(amount > 0, "Invalid liquidation amount");
        require(healthFactor < 10000, "Position is healthy"); // Below 100%
        
        // Generate unique request ID
        requestId = keccak256(abi.encodePacked(
            user, poolId, amount, block.timestamp, block.number
        ));
        
        // Check if emergency liquidation is needed
        bool isEmergency = healthFactor <= config.emergencyThreshold;
        
        // Create liquidation request
        LiquidationRequest storage request = liquidationRequests[requestId];
        request.requestId = requestId;
        request.user = user;
        request.poolId = poolId;
        request.collateralCurrency = collateralCurrency;
        request.debtCurrency = debtCurrency;
        request.totalAmount = amount;
        request.healthFactor = healthFactor;
        request.createdAt = uint32(block.timestamp);
        request.isEmergency = isEmergency;
        
        if (isEmergency) {
            // Execute emergency liquidation immediately
            _executeEmergencyLiquidation(request);
        } else {
            // Calculate optimal chunking strategy
            _calculateOptimalChunks(request, config);
            _scheduleChunks(requestId);
        }
        
        // Add to user's liquidation history
        userLiquidations[user].push(requestId);
        
        emit LiquidationRequested(
            requestId,
            user,
            poolId,
            amount,
            uint8(request.chunks.length),
            healthFactor
        );
        
        return requestId;
    }

    /**
     * @notice Execute the next available chunk from the liquidation queue
     */
    function executeNextChunk() external nonReentrant whenNotPaused returns (bool success) {
        if (liquidationQueue.length == 0) return false;
        
        // Find next executable chunk
        for (uint256 i = 0; i < liquidationQueue.length; i++) {
            QueueEntry storage entry = liquidationQueue[i];
            
            if (block.timestamp >= entry.nextExecutionTime) {
                bytes32 requestId = entry.requestId;
                uint8 chunkIndex = entry.nextChunkIndex;
                
                success = _executeChunk(requestId, chunkIndex, msg.sender);
                
                if (success) {
                    _updateQueueEntry(i);
                    break;
                }
            }
        }
        
        return success;
    }
    
    /**
     * @notice Execute a specific chunk for a liquidation request
     */
    function executeChunk(
        bytes32 requestId,
        uint8 chunkIndex
    ) external nonReentrant whenNotPaused returns (bool success) {
        LiquidationRequest storage request = liquidationRequests[requestId];
        require(request.requestId != bytes32(0), "Liquidation request not found");
        require(chunkIndex < request.chunks.length, "Invalid chunk index");
        
        LiquidationChunk storage chunk = request.chunks[chunkIndex];
        require(!chunk.executed, "Chunk already executed");
        require(block.timestamp >= chunk.executeAfter, "Chunk not ready for execution");
        
        return _executeChunk(requestId, chunkIndex, msg.sender);
    }

    // ============ Internal Functions ============
    
    function _calculateOptimalChunks(
        LiquidationRequest storage request,
        LiquidationConfig memory config
    ) internal {
        MarketConditions memory conditions = marketConditions[request.poolId];
        
        // Update market conditions if stale
        if (block.timestamp - conditions.lastUpdate > 3600) { // 1 hour
            _updateMarketConditions(request.poolId);
            conditions = marketConditions[request.poolId];
        }
        
        // Calculate optimal number of chunks
        uint8 optimalChunks = _calculateOptimalChunkCount(
            request.totalAmount,
            conditions,
            config
        );
        
        // Calculate chunk sizes with progressive sizing
        uint256[] memory chunkSizes = _calculateChunkSizes(
            request.totalAmount,
            optimalChunks,
            conditions
        );
        
        // Create chunks with time delays and market impact estimates
        for (uint8 i = 0; i < optimalChunks; i++) {
            uint32 delay = _calculateChunkDelay(i, conditions, config);
            uint256 marketImpact = _estimateMarketImpact(
                chunkSizes[i],
                conditions
            );
            
            LiquidationChunk memory chunk = LiquidationChunk({
                amount: chunkSizes[i],
                executeAfter: request.createdAt + delay,
                executed: false,
                estimatedGas: _estimateGasForChunk(chunkSizes[i]),
                marketImpact: marketImpact,
                executor: address(0)
            });
            
            request.chunks.push(chunk);
        }
        
        request.status = LiquidationStatus.PENDING;
    }
    
    function _calculateOptimalChunkCount(
        uint256 totalAmount,
        MarketConditions memory conditions,
        LiquidationConfig memory config
    ) internal pure returns (uint8 optimalChunks) {
        // Base chunk count based on total amount
        if (totalAmount >= conditions.averageTradeSize * 20) {
            optimalChunks = MAX_CHUNKS;
        } else if (totalAmount >= conditions.averageTradeSize * 10) {
            optimalChunks = 6;
        } else if (totalAmount >= conditions.averageTradeSize * 5) {
            optimalChunks = 4;
        } else {
            optimalChunks = MIN_CHUNKS;
        }
        
        // Adjust based on volatility
        if (conditions.volatility > 1000) { // High volatility
            optimalChunks = optimalChunks > MIN_CHUNKS ? optimalChunks - 1 : MIN_CHUNKS;
        }
        
        // Respect configuration limits
        if (optimalChunks > config.maxChunks) {
            optimalChunks = config.maxChunks;
        }
        
        return optimalChunks;
    }
    
    function _calculateChunkSizes(
        uint256 totalAmount,
        uint8 chunkCount,
        MarketConditions memory conditions
    ) internal pure returns (uint256[] memory chunkSizes) {
        chunkSizes = new uint256[](chunkCount);
        
        // Use progressive sizing: larger chunks first when volatility is low
        if (conditions.volatility < 500) { // Low volatility
            // Front-load chunks: 40%, 25%, 20%, 15% pattern (for 4 chunks)
            uint256[] memory weights = _getFrontLoadedWeights(chunkCount);
            
            for (uint8 i = 0; i < chunkCount; i++) {
                chunkSizes[i] = (totalAmount * weights[i]) / 10000;
            }
        } else {
            // Even distribution for high volatility
            uint256 baseSize = totalAmount / chunkCount;
            uint256 remainder = totalAmount % chunkCount;
            
            for (uint8 i = 0; i < chunkCount; i++) {
                chunkSizes[i] = baseSize;
                if (i < remainder) {
                    chunkSizes[i] += 1;
                }
            }
        }
        
        return chunkSizes;
    }
    
    function _getFrontLoadedWeights(uint8 chunkCount) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](chunkCount);
        
        if (chunkCount == 3) {
            weights[0] = 5000; // 50%
            weights[1] = 3000; // 30%
            weights[2] = 2000; // 20%
        } else if (chunkCount == 4) {
            weights[0] = 4000; // 40%
            weights[1] = 2500; // 25%
            weights[2] = 2000; // 20%
            weights[3] = 1500; // 15%
        } else if (chunkCount >= 5) {
            weights[0] = 3000; // 30%
            weights[1] = 2000; // 20%
            weights[2] = 1500; // 15%
            weights[3] = 1500; // 15%
            
            uint256 remainingWeight = 2000; // 20% for remaining chunks
            uint256 perChunk = remainingWeight / (chunkCount - 4);
            
            for (uint8 i = 4; i < chunkCount; i++) {
                weights[i] = perChunk;
            }
        }
        
        return weights;
    }
    
    function _calculateChunkDelay(
        uint8 chunkIndex,
        MarketConditions memory conditions,
        LiquidationConfig memory config
    ) internal pure returns (uint32 delay) {
        // Base delay increases with chunk index
        delay = config.baseDelay * (chunkIndex + 1);
        
        // Adjust based on volatility
        if (conditions.volatility > 1000) { // High volatility
            delay = delay * 150 / 100; // 50% longer delays
        } else if (conditions.volatility < 300) { // Low volatility
            delay = delay * 75 / 100; // 25% shorter delays
        }
        
        // Ensure within bounds
        if (delay < MIN_CHUNK_DELAY) delay = MIN_CHUNK_DELAY;
        if (delay > MAX_CHUNK_DELAY) delay = MAX_CHUNK_DELAY;
        
        return delay;
    }
    
    function _scheduleChunks(bytes32 requestId) internal {
        LiquidationRequest storage request = liquidationRequests[requestId];
        
        for (uint8 i = 0; i < request.chunks.length; i++) {
            if (!request.chunks[i].executed) {
                QueueEntry memory entry = QueueEntry({
                    requestId: requestId,
                    priority: _calculatePriority(request),
                    nextExecutionTime: request.chunks[i].executeAfter,
                    nextChunkIndex: i
                });
                
                _insertIntoQueue(entry);
            }
        }
        
        request.status = LiquidationStatus.ACTIVE;
    }
    
    function _calculatePriority(
        LiquidationRequest storage request
    ) internal view returns (uint8 priority) {
        // Lower number = higher priority
        if (request.healthFactor <= 3000) return 0; // Critical health
        if (request.healthFactor <= 5000) return 1; // Low health
        if (request.healthFactor <= 7000) return 2; // Medium health
        return 3; // Normal priority
    }
    
    function _insertIntoQueue(QueueEntry memory entry) internal {
        liquidationQueue.push();
        uint256 index = liquidationQueue.length - 1;
        
        // Bubble up to maintain priority order
        while (index > 0 && liquidationQueue[index - 1].priority > entry.priority) {
            liquidationQueue[index] = liquidationQueue[index - 1];
            index--;
        }
        
        liquidationQueue[index] = entry;
    }
    
    function _executeEmergencyLiquidation(
        LiquidationRequest storage request
    ) internal {
        request.status = LiquidationStatus.EMERGENCY;
        request.isEmergency = true;
        
        // Execute full liquidation immediately
        _performLiquidation(
            request.user,
            request.collateralCurrency,
            request.debtCurrency,
            request.totalAmount,
            msg.sender
        );
        
        // Higher reward for emergency liquidation
        LiquidationConfig memory config = liquidationConfigs[request.poolId];
        uint256 emergencyReward = _calculateReward(
            request.totalAmount,
            config.liquidatorReward * 150 / 100 // 50% bonus for emergency
        );
        
        _distributeReward(msg.sender, emergencyReward);
        
        request.totalRewardsPaid = emergencyReward;
        totalValueLiquidated += request.totalAmount;
        
        emit EmergencyLiquidationTriggered(
            request.requestId,
            request.user,
            request.totalAmount,
            request.healthFactor
        );
        
        emit LiquidationCompleted(
            request.requestId,
            request.user,
            request.totalAmount,
            request.totalRewardsPaid
        );
    }
    
    /**
     * @notice Execute a single liquidation chunk
     */
    function _executeChunk(
        bytes32 requestId,
        uint8 chunkIndex,
        address executor
    ) internal returns (bool success) {
        LiquidationRequest storage request = liquidationRequests[requestId];
        LiquidationChunk storage chunk = request.chunks[chunkIndex];
        
        // Verify execution conditions
        require(block.timestamp >= chunk.executeAfter, "Chunk not ready");
        require(!chunk.executed, "Already executed");
        require(chunk.estimatedGas <= MAX_GAS_PER_CHUNK, "Gas limit exceeded");
        
        // Check if emergency liquidation is now needed
        uint256 currentHealthFactor = _getCurrentHealthFactor(request.user, request.poolId);
        LiquidationConfig memory config = liquidationConfigs[request.poolId];
        
        if (currentHealthFactor <= config.emergencyThreshold) {
            _triggerEmergencyLiquidation(request);
            return false;
        }
        
        // Execute the actual liquidation
        uint256 actualImpact = _performLiquidation(
            request.user,
            request.collateralCurrency,
            request.debtCurrency,
            chunk.amount,
            executor
        );
        
        // Mark chunk as executed
        chunk.executed = true;
        chunk.executor = executor;
        request.lastChunkTime = uint32(block.timestamp);
        
        // Calculate and distribute rewards
        uint256 reward = _calculateReward(chunk.amount, config.liquidatorReward);
        _distributeReward(executor, reward);
        
        request.totalRewardsPaid += reward;
        liquidatorRewards[executor] += reward;
        liquidatorExecutions[executor]++;
        
        // Update global statistics
        totalValueLiquidated += chunk.amount;
        
        // Check if liquidation is complete
        if (_isLiquidationComplete(request)) {
            request.status = LiquidationStatus.COMPLETED;
            emit LiquidationCompleted(
                requestId,
                request.user,
                request.totalAmount,
                request.totalRewardsPaid
            );
        }
        
        emit ChunkExecuted(
            requestId,
            chunkIndex,
            executor,
            chunk.amount,
            actualImpact,
            reward
        );
        
        return true;
    }
    
    /**
     * @notice Update queue entry after chunk execution
     */
    function _updateQueueEntry(uint256 queueIndex) internal {
        QueueEntry storage entry = liquidationQueue[queueIndex];
        LiquidationRequest storage request = liquidationRequests[entry.requestId];
        
        // Find next unexecuted chunk
        bool hasNextChunk = false;
        for (uint8 i = entry.nextChunkIndex + 1; i < request.chunks.length; i++) {
            if (!request.chunks[i].executed) {
                entry.nextChunkIndex = i;
                entry.nextExecutionTime = request.chunks[i].executeAfter;
                hasNextChunk = true;
                break;
            }
        }
        
        // Remove from queue if no more chunks
        if (!hasNextChunk) {
            _removeFromQueue(queueIndex);
        }
    }
    
    /**
     * @notice Remove entry from queue
     */
    function _removeFromQueue(uint256 index) internal {
        require(index < liquidationQueue.length, "Invalid queue index");
        
        for (uint256 i = index; i < liquidationQueue.length - 1; i++) {
            liquidationQueue[i] = liquidationQueue[i + 1];
        }
        liquidationQueue.pop();
    }
    
    /**
     * @notice Get current health factor for a user position
     */
    function _getCurrentHealthFactor(address /* user */, PoolId /* poolId */) internal pure returns (uint256) {
        // Placeholder for health factor calculation
        // In production, this would query the lending protocol
        return 8000; // 80% healthy by default
    }
    
    /**
     * @notice Trigger emergency liquidation for entire remaining amount
     */
    function _triggerEmergencyLiquidation(LiquidationRequest storage request) internal {
        uint256 remainingAmount = _calculateRemainingAmount(request);
        
        if (remainingAmount > 0) {
            _executeEmergencyLiquidation(request);
        }
    }
    
    /**
     * @notice Calculate remaining amount to be liquidated
     */
    function _calculateRemainingAmount(
        LiquidationRequest storage request
    ) internal view returns (uint256 remaining) {
        remaining = request.totalAmount;
        
        for (uint256 i = 0; i < request.chunks.length; i++) {
            if (request.chunks[i].executed) {
                remaining -= request.chunks[i].amount;
            }
        }
    }
    
    /**
     * @notice Check if liquidation is complete
     */
    function _isLiquidationComplete(
        LiquidationRequest storage request
    ) internal view returns (bool complete) {
        for (uint256 i = 0; i < request.chunks.length; i++) {
            if (!request.chunks[i].executed) {
                return false;
            }
        }
        return true;
    }
    
    // ============ Helper Functions ============
    
    function _estimateMarketImpact(
        uint256 amount,
        MarketConditions memory conditions
    ) internal pure returns (uint256 impact) {
        if (conditions.liquidityDepth == 0) return 0;
        
        // Basic market impact model: impact = (amount / liquidity) * volatility_factor
        uint256 baseImpact = (amount * 10000) / conditions.liquidityDepth;
        uint256 volatilityMultiplier = 10000 + conditions.volatility;
        
        impact = (baseImpact * volatilityMultiplier) / 10000;
        
        // Cap at reasonable maximum
        if (impact > 2000) impact = 2000; // 20% max impact
        
        return impact;
    }
    
    function _updateMarketConditions(PoolId poolId) internal {
        MarketConditions storage conditions = marketConditions[poolId];
        
        // In production, these would be calculated from on-chain data
        conditions.volatility = 500; // 5% baseline volatility
        conditions.liquidityDepth = 1000000e18; // $1M baseline liquidity
        conditions.averageTradeSize = 10000e18; // $10K baseline average trade
        conditions.gasPrice = tx.gasprice;
        conditions.lastUpdate = uint32(block.timestamp);
        
        emit MarketConditionsUpdated(
            poolId,
            conditions.volatility,
            conditions.liquidityDepth
        );
    }
    
    function _performLiquidation(
        address /* user */,
        Currency /* collateralCurrency */,
        Currency /* debtCurrency */,
        uint256 amount,
        address /* liquidator */
    ) internal view returns (uint256 actualImpact) {
        // Placeholder for actual liquidation logic
        return _estimateMarketImpact(amount, marketConditions[PoolId.wrap(bytes32(0))]);
    }
    
    function _calculateReward(
        uint256 amount,
        uint256 rewardRate
    ) internal pure returns (uint256) {
        return (amount * rewardRate) / 10000;
    }
    
    function _distributeReward(address liquidator, uint256 reward) internal {
        // Placeholder for reward distribution
    }
    
    function _estimateGasForChunk(uint256 amount) internal pure returns (uint256) {
        return 100000 + (amount / 1e18) * 1000;
    }
    
    // ============ Admin Functions ============
    
    function configureLiquidation(
        PoolId poolId,
        LiquidationConfig calldata config
    ) external onlyOwner {
        require(config.maxChunks >= MIN_CHUNKS && config.maxChunks <= MAX_CHUNKS, "Invalid chunk count");
        require(config.baseDelay >= MIN_CHUNK_DELAY && config.baseDelay <= MAX_CHUNK_DELAY, "Invalid delay");
        require(config.maxMarketImpact <= 2000, "Market impact too high"); // Max 20%
        
        liquidationConfigs[poolId] = config;
        
        emit ChunkingConfigUpdated(poolId, config);
    }
    
    /**
     * @notice Add emergency liquidator
     */
    function addEmergencyLiquidator(address liquidator) external onlyOwner {
        emergencyLiquidators[liquidator] = true;
    }
    
    /**
     * @notice Remove emergency liquidator
     */
    function removeEmergencyLiquidator(address liquidator) external onlyOwner {
        emergencyLiquidators[liquidator] = false;
    }
    
    /**
     * @notice Toggle emergency mode
     */
    function setEmergencyMode(bool _emergencyMode) external onlyOwner {
        emergencyMode = _emergencyMode;
    }
    
    /**
     * @notice Update global liquidator reward rate
     */
    function setGlobalLiquidatorReward(uint256 reward) external onlyOwner {
        require(reward <= 1000, "Reward too high"); // Max 10%
        globalLiquidatorReward = reward;
    }
    
    /**
     * @notice Pause contract
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ============ View Functions ============
    
    function getLiquidationRequest(bytes32 requestId) external view returns (
        address user,
        PoolId poolId,
        uint256 totalAmount,
        uint256 healthFactor,
        LiquidationStatus status,
        uint8 chunkCount,
        uint8 executedChunks
    ) {
        LiquidationRequest storage request = liquidationRequests[requestId];
        
        uint8 executed = 0;
        for (uint256 i = 0; i < request.chunks.length; i++) {
            if (request.chunks[i].executed) executed++;
        }
        
        return (
            request.user,
            request.poolId,
            request.totalAmount,
            request.healthFactor,
            request.status,
            uint8(request.chunks.length),
            executed
        );
    }
    
    /**
     * @notice Get chunk details for a liquidation
     */
    function getChunkDetails(bytes32 requestId, uint8 chunkIndex) external view returns (
        uint256 amount,
        uint32 executeAfter,
        bool executed,
        uint256 estimatedGas,
        uint256 marketImpact,
        address executor
    ) {
        LiquidationRequest storage request = liquidationRequests[requestId];
        require(chunkIndex < request.chunks.length, "Invalid chunk index");
        
        LiquidationChunk storage chunk = request.chunks[chunkIndex];
        return (
            chunk.amount,
            chunk.executeAfter,
            chunk.executed,
            chunk.estimatedGas,
            chunk.marketImpact,
            chunk.executor
        );
    }
    
    /**
     * @notice Get liquidation queue length
     */
    function getQueueLength() external view returns (uint256) {
        return liquidationQueue.length;
    }
    
    /**
     * @notice Get next executable chunk from queue
     */
    function getNextExecutableChunk() external view returns (
        bytes32 requestId,
        uint8 chunkIndex,
        uint32 executeAfter,
        uint8 priority
    ) {
        for (uint256 i = 0; i < liquidationQueue.length; i++) {
            QueueEntry storage entry = liquidationQueue[i];
            if (block.timestamp >= entry.nextExecutionTime) {
                return (
                    entry.requestId,
                    entry.nextChunkIndex,
                    entry.nextExecutionTime,
                    entry.priority
                );
            }
        }
        
        // No executable chunks found
        return (bytes32(0), 0, 0, 255);
    }
    
    /**
     * @notice Get liquidator statistics
     */
    function getLiquidatorStats(address liquidator) external view returns (
        uint256 totalRewards,
        uint256 totalExecutions,
        bool isEmergencyLiquidator
    ) {
        return (
            liquidatorRewards[liquidator],
            liquidatorExecutions[liquidator],
            emergencyLiquidators[liquidator]
        );
    }
    
    /**
     * @notice Get global liquidation statistics
     */
    function getGlobalStats() external view returns (
        uint256 totalProcessed,
        uint256 totalValue,
        uint256 queueLength,
        bool emergencyModeActive
    ) {
        return (
            totalLiquidationsProcessed,
            totalValueLiquidated,
            liquidationQueue.length,
            emergencyMode
        );
    }
    
    /**
     * @notice Get pool liquidation configuration
     */
    function getPoolConfig(PoolId poolId) external view returns (LiquidationConfig memory) {
        return liquidationConfigs[poolId];
    }
    
    /**
     * @notice Get market conditions for a pool
     */
    function getMarketConditions(PoolId poolId) external view returns (MarketConditions memory) {
        return marketConditions[poolId];
    }
    
    /**
     * @notice Get user liquidation history
     */
    function getUserLiquidationHistory(address user) external view returns (bytes32[] memory) {
        return userLiquidations[user];
    }
    
    /**
     * @notice Check if liquidation can be executed immediately
     */
    function canExecuteChunk(bytes32 requestId, uint8 chunkIndex) external view returns (bool) {
        LiquidationRequest storage request = liquidationRequests[requestId];
        if (chunkIndex >= request.chunks.length) return false;
        
        LiquidationChunk storage chunk = request.chunks[chunkIndex];
        return !chunk.executed && block.timestamp >= chunk.executeAfter;
    }
    
    /**
     * @notice Get estimated rewards for executing a chunk
     */
    function getEstimatedReward(bytes32 requestId, uint8 chunkIndex) external view returns (uint256) {
        LiquidationRequest storage request = liquidationRequests[requestId];
        if (chunkIndex >= request.chunks.length) return 0;
        
        LiquidationConfig memory config = liquidationConfigs[request.poolId];
        return _calculateReward(request.chunks[chunkIndex].amount, config.liquidatorReward);
    }
} 