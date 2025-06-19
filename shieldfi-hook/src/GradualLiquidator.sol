// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IGradualLiquidator.sol";
import "./interfaces/ICircleUSDCVault.sol";
import "./interfaces/IMEVDetector.sol";

/**
 * @title GradualLiquidator
 * @notice Manages gradual liquidations to minimize MEV extraction and protect users
 * @dev Implements time-based chunked liquidations with market condition monitoring
 */
contract GradualLiquidator is IGradualLiquidator, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                        STATE VARIABLES
    // =============================================================

    ICircleUSDCVault public immutable vault;
    IMEVDetector public immutable mevDetector;
    IERC20 public immutable usdcToken;

    // Liquidation tracking
    mapping(bytes32 => LiquidationChunk[]) public liquidationChunks;
    mapping(bytes32 => bool) public activeLiquidations;
    mapping(address => bytes32[]) public userLiquidations;

    // Configuration
    LiquidationConfig public config;

    // Global configuration
    uint256 public constant MIN_CHUNK_DELAY = 300; // 5 minutes minimum
    uint256 public constant MAX_CHUNK_DELAY = 3600; // 1 hour maximum
    uint256 public constant MIN_CHUNK_SIZE = 100; // $100 minimum
    uint256 public constant MAX_CHUNKS_PER_LIQUIDATION = 50;
    uint256 public constant LIQUIDATION_TIMEOUT = 86400; // 24 hours

    // Access control
    address public shieldFiHook;
    mapping(address => bool) public authorizedLiquidators;

    // Statistics
    uint256 public totalLiquidationsStarted;
    uint256 public totalLiquidationsCompleted;
    uint256 public totalValueLiquidated;

    // Health factor monitoring
    mapping(address => uint256) public lastHealthFactorCheck;
    mapping(address => uint256) public healthFactorTrend; // 0 = stable, 1 = improving, 2 = deteriorating
    
    // Liquidation rewards
    mapping(address => uint256) public liquidatorRewards;
    mapping(bytes32 => uint256) public chunkRewards;
    uint256 public constant BASE_LIQUIDATION_REWARD = 50; // 0.5% base reward
    uint256 public constant EARLY_EXECUTION_BONUS = 25; // 0.25% bonus for early execution
    uint256 public constant COMPLETION_BONUS = 100; // 1% bonus for completing full liquidation
    
    // Gas optimization tracking
    mapping(bytes32 => uint256) public liquidationGasUsed;
    uint256 public constant MAX_GAS_PER_CHUNK = 200000; // Maximum gas per chunk execution

    // =============================================================
    //                        EVENTS
    // =============================================================

    // Events are defined in the interface IGradualLiquidator

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

    modifier validLiquidation(bytes32 liquidationId) {
        require(activeLiquidations[liquidationId], "Liquidation not active");
        _;
    }

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(
        address _vault,
        address _mevDetector,
        address _usdcToken
    ) Ownable(msg.sender) {
        vault = ICircleUSDCVault(_vault);
        mevDetector = IMEVDetector(_mevDetector);
        usdcToken = IERC20(_usdcToken);
        
        // Initialize default configuration
        config = LiquidationConfig({
            minChunkSize: 100e6, // $100 USDC
            maxChunkSize: 10000e6, // $10,000 USDC
            chunkDelay: 600, // 10 minutes
            maxMarketImpact: 500, // 5% max market impact
            emergencyMode: false
        });
    }

    // =============================================================
    //                        VIEW FUNCTIONS (MOVED UP)
    // =============================================================

    function calculateOptimalChunking(
        uint256 totalAmount,
        uint256 healthFactor,
        MarketConditions calldata conditions
    ) external view override returns (
        uint256 chunks,
        uint256[] memory chunkSizes,
        uint256[] memory delays
    ) {
        // Optimal chunk calculation based on position size and health factor
        // Target 3-8 chunks for optimal gas efficiency and MEV protection
        uint256 baseChunks;
        
        // Determine optimal chunk count based on amount and health factor
        if (totalAmount <= 1000e6) { // $1,000 or less
            baseChunks = 3;
        } else if (totalAmount <= 5000e6) { // $1,000 - $5,000
            baseChunks = healthFactor < 105 ? 6 : 4; // More chunks for unhealthier positions
        } else if (totalAmount <= 10000e6) { // $5,000 - $10,000
            baseChunks = healthFactor < 105 ? 8 : 6;
        } else { // > $10,000
            baseChunks = healthFactor < 105 ? 8 : 7;
        }
        
        // Adjust based on market conditions
        if (conditions.volatility > 500) { // 5% volatility threshold
            baseChunks = baseChunks > 3 ? baseChunks + 1 : baseChunks; // Add chunk in volatile markets
        }
        
        if (conditions.liquidity < 10000e6) { // $10M liquidity threshold
            baseChunks = baseChunks > 3 ? baseChunks + 1 : baseChunks; // Add chunk in low liquidity
        }

        // Ensure chunk count is within 3-8 range
        chunks = baseChunks > 8 ? 8 : (baseChunks < 3 ? 3 : baseChunks);
        
        // Calculate chunk sizes
        chunkSizes = new uint256[](chunks);
        delays = new uint256[](chunks);
        
        uint256 baseChunkSize = totalAmount / chunks;
        uint256 remainingAmount = totalAmount;
        
        // Progressive chunk sizing - start smaller, end larger for better market impact distribution
        for (uint256 i = 0; i < chunks; i++) {
            if (i == chunks - 1) {
                // Last chunk gets remaining amount
                chunkSizes[i] = remainingAmount;
            } else {
                // Progressive sizing: first chunks are smaller
                uint256 progressiveFactor = 8000 + (i * 2000 / chunks); // 80% to 100% scaling
                uint256 chunkSize = (baseChunkSize * progressiveFactor) / 10000;
                
                // Ensure bounds
                if (chunkSize < config.minChunkSize) {
                    chunkSize = config.minChunkSize;
                } else if (chunkSize > config.maxChunkSize) {
                    chunkSize = config.maxChunkSize;
                }
                
                chunkSizes[i] = chunkSize;
                remainingAmount -= chunkSize;
            }
            
            // Progressive delays - longer delays for later chunks to prevent market manipulation
            uint256 baseDelay = config.chunkDelay;
            if (healthFactor < 105) { // Critical health factor
                delays[i] = baseDelay / 2; // Faster execution for critical positions
            } else {
                delays[i] = baseDelay + (i * baseDelay / 4); // Progressive delays
            }
        }

        return (chunks, chunkSizes, delays);
    }

    // =============================================================
    //                        CORE LIQUIDATION FUNCTIONS
    // =============================================================

    function liquidateGradually(
        address borrower,
        uint256 totalAmount,
        uint256 maxChunks
    ) external override nonReentrant onlyAuthorizedLiquidator returns (bytes32 liquidationId) {
        require(totalAmount > config.minChunkSize, "Amount too small");
        require(maxChunks > 0 && maxChunks <= MAX_CHUNKS_PER_LIQUIDATION, "Invalid chunk count");

        // Generate unique liquidation ID
        liquidationId = keccak256(abi.encodePacked(
            borrower,
            totalAmount,
            maxChunks,
            block.timestamp,
            totalLiquidationsStarted
        ));

        // Check if position is liquidatable
        (bool isLiquidatable,) = vault.isPositionLiquidatable(borrower);
        require(isLiquidatable, "Position not liquidatable");

        // Calculate optimal chunking strategy, but respect maxChunks
        MarketConditions memory conditions = _getCurrentMarketConditions();
        (uint256 optimalChunks, uint256[] memory chunkSizes, uint256[] memory delays) = this.calculateOptimalChunking(
            totalAmount,
            110, // Default health factor threshold
            conditions
        );
        
        // Use the minimum of optimal chunks and maxChunks requested
        uint256 chunks = optimalChunks > maxChunks ? maxChunks : optimalChunks;
        
        // If we need to reduce chunks, recalculate with the constrained amount
        if (chunks != optimalChunks) {
            // Simple equal distribution when constrained by maxChunks
            chunkSizes = new uint256[](chunks);
            delays = new uint256[](chunks);
            
            uint256 baseChunkSize = totalAmount / chunks;
            uint256 remainingAmount = totalAmount;
            
            for (uint256 i = 0; i < chunks; i++) {
                if (i == chunks - 1) {
                    chunkSizes[i] = remainingAmount;
                } else {
                    chunkSizes[i] = baseChunkSize;
                    remainingAmount -= baseChunkSize;
                }
                delays[i] = config.chunkDelay;
            }
        }

        // Create liquidation chunks
        _createLiquidationChunks(liquidationId, borrower, chunkSizes, delays);

        // Mark as active
        activeLiquidations[liquidationId] = true;
        userLiquidations[borrower].push(liquidationId);

        // Update statistics
        totalLiquidationsStarted++;

        emit LiquidationStarted(liquidationId, borrower, totalAmount, chunks);

        return liquidationId;
    }

    function executeNextChunk(bytes32 liquidationId) external override nonReentrant validLiquidation(liquidationId) returns (bool success, uint256 chunkAmount) {
        uint256 gasStart = gasleft();
        
        LiquidationChunk[] storage chunks = liquidationChunks[liquidationId];
        
        // Find next executable chunk
        uint256 nextChunkIndex = _findNextExecutableChunk(liquidationId);
        if (nextChunkIndex >= chunks.length) {
            return (false, 0);
        }

        LiquidationChunk storage chunk = chunks[nextChunkIndex];
        if (chunk.executed || block.timestamp < chunk.executionTime) {
            return (false, 0);
        }

        // Check for MEV activity before execution
        {
            bool mevDetected = _checkMEVActivity(chunk.borrower, chunk.chunkAmount);
            
            if (mevDetected && !config.emergencyMode) {
                // Delay execution if MEV detected
                chunk.executionTime = block.timestamp + config.chunkDelay;
                return (false, 0);
            }
        }

        // Monitor health factor before execution
        {
            (uint256 healthFactor, uint256 trend) = monitorHealthFactor(chunk.borrower);
            
            // Check if emergency liquidation should be triggered
            if (healthFactor < 102 || (healthFactor < 105 && trend == 2)) {
                // Trigger emergency liquidation for remaining chunks
                _triggerEmergencyLiquidation(liquidationId, "Critical health factor detected");
                return (true, chunk.chunkAmount);
            }
        }

        // Execute the liquidation chunk
        success = _executeLiquidationChunk(liquidationId, nextChunkIndex);
        chunkAmount = chunk.chunkAmount;

        if (success) {
            // Get original execution time before it's overwritten
            uint256 originalExecutionTime = liquidationChunks[liquidationId][nextChunkIndex].executionTime;
            
            // Process rewards and completion in separate scope to manage stack
            _processChunkCompletion(liquidationId, nextChunkIndex, chunkAmount, gasStart, originalExecutionTime);
        }

        return (success, chunkAmount);
    }

    function getLiquidationStatus(bytes32 liquidationId) external view override returns (
        address borrower,
        uint256 totalAmount,
        uint256 executedAmount,
        uint256 chunksRemaining,
        uint256 nextExecutionTime
    ) {
        if (!activeLiquidations[liquidationId]) {
            return (address(0), 0, 0, 0, 0);
        }

        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        if (chunks.length == 0) {
            return (address(0), 0, 0, 0, 0);
        }

        borrower = chunks[0].borrower;
        
        for (uint256 i = 0; i < chunks.length; i++) {
            totalAmount += chunks[i].chunkAmount;
            if (chunks[i].executed) {
                executedAmount += chunks[i].chunkAmount;
            } else {
                chunksRemaining++;
                if (nextExecutionTime == 0) {
                    nextExecutionTime = chunks[i].executionTime;
                }
            }
        }
    }

    function getChunkDetails(bytes32 liquidationId, uint256 chunkIndex) external view override returns (LiquidationChunk memory chunk) {
        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        require(chunkIndex < chunks.length, "Invalid chunk index");
        return chunks[chunkIndex];
    }

    function calculateMarketImpact(uint256 amount, uint256 poolLiquidity) external pure override returns (uint256 marketImpact) {
        if (poolLiquidity == 0) {
            return 10000; // 100% impact if no liquidity
        }
        
        // Simple market impact calculation: impact = (amount / liquidity) * 10000
        marketImpact = (amount * 10000) / poolLiquidity;
        
        // Cap at 100%
        if (marketImpact > 10000) {
            marketImpact = 10000;
        }
    }

    function pauseLiquidation(bytes32 liquidationId, string calldata reason) external override onlyAuthorizedLiquidator validLiquidation(liquidationId) {
        // Implementation would pause the liquidation
        emit EmergencyLiquidation(liquidationId, address(0), 0, reason);
    }

    function resumeLiquidation(bytes32 liquidationId) external override onlyAuthorizedLiquidator validLiquidation(liquidationId) {
        // Implementation would resume the liquidation
    }

    function emergencyLiquidate(bytes32 liquidationId, string calldata reason) external override onlyShieldFiHook validLiquidation(liquidationId) {
        LiquidationChunk[] storage chunks = liquidationChunks[liquidationId];
        
        // Calculate remaining amount
        uint256 remainingAmount = 0;
        address borrower = address(0);
        
        for (uint256 i = 0; i < chunks.length; i++) {
            if (borrower == address(0)) {
                borrower = chunks[i].borrower;
            }
            if (!chunks[i].executed) {
                remainingAmount += chunks[i].chunkAmount;
                chunks[i].executed = true;
                chunks[i].executionTime = block.timestamp;
            }
        }
        
        if (remainingAmount > 0) {
            // Execute emergency liquidation through vault
            vault.emergencyLiquidate(borrower, remainingAmount);
        }
        
        // Complete the liquidation
        _completeLiquidation(liquidationId);
        
        emit EmergencyLiquidation(liquidationId, borrower, remainingAmount, reason);
    }

    function updateConfig(LiquidationConfig calldata _config) external override onlyOwner {
        config = _config;
        emit ConfigUpdated(_config.minChunkSize, _config.maxChunkSize, _config.chunkDelay, _config.maxMarketImpact);
    }

    function getConfig() external view override returns (LiquidationConfig memory) {
        return config;
    }

    function getMarketConditions() external view override returns (MarketConditions memory conditions) {
        return _getCurrentMarketConditions();
    }

    function canExecuteNext(bytes32 liquidationId) external view override returns (bool canExecute, string memory reason) {
        if (!activeLiquidations[liquidationId]) {
            return (false, "Liquidation not active");
        }

        // Simplified check - just verify liquidation exists
        // Full execution logic is handled in executeNextChunk
        return (true, "");
    }

    function _findNextExecutableChunkView(bytes32 liquidationId) internal view returns (uint256) {
        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        
        for (uint256 i = 0; i < chunks.length; i++) {
            if (!chunks[i].executed && block.timestamp >= chunks[i].executionTime) {
                return i;
            }
        }
        
        return type(uint256).max; // No executable chunk found
    }

    function getActiveLiquidationCount() external view override returns (uint256 count) {
        // This is a simplified implementation - in production you'd want to track this more efficiently
        count = 0;
        // Note: This is not gas efficient for large numbers of liquidations
        // In production, you'd maintain a counter
        return totalLiquidationsStarted - totalLiquidationsCompleted;
    }

    function getActiveLiquidations(uint256 /* offset */, uint256 /* limit */) external pure override returns (bytes32[] memory liquidationIds) {
        // This is a simplified implementation - in production you'd maintain an active liquidations array
        // For now, return empty array as this would require significant refactoring to implement efficiently
        liquidationIds = new bytes32[](0);
        return liquidationIds;
    }

    // =============================================================
    //                     HEALTH FACTOR MONITORING
    // =============================================================

    function monitorHealthFactor(address borrower) public returns (uint256 currentHealthFactor, uint256 trend) {
        currentHealthFactor = vault.getHealthFactor(borrower);
        uint256 lastHealthFactor = lastHealthFactorCheck[borrower];
        
        if (lastHealthFactor == 0) {
            // First check
            trend = 0; // stable
        } else if (currentHealthFactor > lastHealthFactor + 5) { // 5% improvement threshold
            trend = 1; // improving
        } else if (currentHealthFactor < lastHealthFactor - 5) { // 5% deterioration threshold
            trend = 2; // deteriorating
        } else {
            trend = 0; // stable
        }
        
        lastHealthFactorCheck[borrower] = currentHealthFactor;
        healthFactorTrend[borrower] = trend;
        
        // Emit event for monitoring
        emit HealthFactorUpdated(borrower, currentHealthFactor, trend);
        
        return (currentHealthFactor, trend);
    }

    function getHealthFactorTrend(address borrower) external view returns (uint256 trend, uint256 lastCheck) {
        return (healthFactorTrend[borrower], lastHealthFactorCheck[borrower]);
    }

    function shouldTriggerEmergencyLiquidation(address borrower) external returns (bool shouldTrigger, string memory reason) {
        (uint256 healthFactor, uint256 trend) = monitorHealthFactor(borrower);
        
        if (healthFactor < 102) { // Critical health factor
            return (true, "Critical health factor below 1.02");
        }
        
        if (healthFactor < 105 && trend == 2) { // Deteriorating trend
            return (true, "Deteriorating health factor trend");
        }
        
        return (false, "");
    }

    // =============================================================
    //                     LIQUIDATION REWARDS
    // =============================================================

    function calculateChunkReward(
        bytes32 liquidationId,
        uint256 /* chunkIndex */,
        uint256 chunkAmount,
        bool isEarlyExecution
    ) public view returns (uint256 reward) {
        // Base reward calculation
        reward = (chunkAmount * BASE_LIQUIDATION_REWARD) / 10000;
        
        // Early execution bonus
        if (isEarlyExecution) {
            reward += (chunkAmount * EARLY_EXECUTION_BONUS) / 10000;
        }
        
        // Health factor bonus - higher rewards for riskier liquidations
        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        if (chunks.length > 0) {
            address borrower = chunks[0].borrower;
            uint256 healthFactor = vault.getHealthFactor(borrower);
            
            if (healthFactor < 105) { // Critical positions get higher rewards
                reward = (reward * 150) / 100; // 50% bonus
            } else if (healthFactor < 110) {
                reward = (reward * 125) / 100; // 25% bonus
            }
        }
        
        return reward;
    }

    function processLiquidationReward(
        address liquidator,
        bytes32 liquidationId,
        uint256 chunkIndex,
        uint256 chunkAmount,
        bool isEarlyExecution
    ) internal {
        uint256 reward = calculateChunkReward(liquidationId, chunkIndex, chunkAmount, isEarlyExecution);
        
        // Store chunk reward
        chunkRewards[keccak256(abi.encodePacked(liquidationId, chunkIndex))] = reward;
        
        // Add to liquidator's total rewards
        liquidatorRewards[liquidator] += reward;
        
        // Transfer reward (in practice, this would be from a reward pool)
        emit LiquidationReward(liquidator, liquidationId, chunkIndex, reward);
    }

    function processCompletionBonus(address liquidator, bytes32 liquidationId, uint256 totalAmount) internal {
        uint256 completionBonus = (totalAmount * COMPLETION_BONUS) / 10000;
        liquidatorRewards[liquidator] += completionBonus;
        
        emit CompletionBonus(liquidator, liquidationId, completionBonus);
    }

    function claimRewards() external nonReentrant {
        uint256 rewards = liquidatorRewards[msg.sender];
        require(rewards > 0, "No rewards to claim");
        
        liquidatorRewards[msg.sender] = 0;
        
        // In practice, transfer rewards from reward pool
        emit RewardsClaimed(msg.sender, rewards);
    }

    function getLiquidatorRewards(address liquidator) external view returns (uint256 rewards) {
        return liquidatorRewards[liquidator];
    }

    // =============================================================
    //                     GAS OPTIMIZATION
    // =============================================================

    function checkGasOptimization(bytes32 liquidationId) public view returns (bool isOptimal, uint256 estimatedGas) {
        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        
        // Estimate gas for chunk execution
        estimatedGas = 50000 + (chunks.length * 30000); // Base + per chunk
        
        // Check if within optimal range
        isOptimal = estimatedGas <= MAX_GAS_PER_CHUNK;
        
        return (isOptimal, estimatedGas);
    }

    // =============================================================
    //                        INTERNAL FUNCTIONS
    // =============================================================

    function _createLiquidationChunks(
        bytes32 liquidationId,
        address borrower,
        uint256[] memory chunkSizes,
        uint256[] memory delays
    ) internal {
        uint256 currentTime = block.timestamp;
        uint256 cumulativeDelay = 0;
        
        for (uint256 i = 0; i < chunkSizes.length; i++) {
            liquidationChunks[liquidationId].push(LiquidationChunk({
                liquidationId: liquidationId,
                borrower: borrower,
                chunkAmount: chunkSizes[i],
                chunkIndex: i,
                totalChunks: chunkSizes.length,
                executionTime: currentTime + cumulativeDelay,
                executed: false,
                marketImpact: 0
            }));
            
            // Add current delay to cumulative for next chunk
            if (i < delays.length) {
                cumulativeDelay += delays[i];
            }
        }
    }

    function _findNextExecutableChunk(bytes32 liquidationId) internal view returns (uint256) {
        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        
        for (uint256 i = 0; i < chunks.length; i++) {
            if (!chunks[i].executed && block.timestamp >= chunks[i].executionTime) {
                return i;
            }
        }
        
        return type(uint256).max; // No executable chunk found
    }

    function _executeLiquidationChunk(bytes32 liquidationId, uint256 chunkIndex) internal returns (bool success) {
        LiquidationChunk storage chunk = liquidationChunks[liquidationId][chunkIndex];

        try vault.liquidate(chunk.borrower, chunk.chunkAmount, address(usdcToken)) {
            // Mark chunk as executed
            chunk.executed = true;
            chunk.executionTime = block.timestamp;

            // Update statistics
            totalValueLiquidated += chunk.chunkAmount;

            emit ChunkExecuted(liquidationId, chunkIndex, chunk.chunkAmount, chunk.marketImpact);
            return true;
        } catch {
            return false;
        }
    }

    function _checkMEVActivity(address borrower, uint256 amount) internal returns (bool) {
        // Check for MEV activity using the MEV detector
        // Get borrower's health factor from vault
        ICircleUSDCVault.UserPosition memory position = vault.getUserPosition(borrower);
        
        // Use flagLiquidation to check if this liquidation needs MEV protection
        try mevDetector.flagLiquidation(borrower, amount, position.healthFactor) returns (bool requiresProtection) {
            return requiresProtection;
        } catch {
            // If MEV detector fails, err on the side of caution
            return true;
        }
    }

    function _isLiquidationComplete(bytes32 liquidationId) internal view returns (bool) {
        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        
        for (uint256 i = 0; i < chunks.length; i++) {
            if (!chunks[i].executed) {
                return false;
            }
        }
        
        return true;
    }

    function _completeLiquidation(bytes32 liquidationId) internal {
        activeLiquidations[liquidationId] = false;

        // Calculate total executed and market impact
        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        uint256 totalExecuted = 0;
        uint256 totalMarketImpact = 0;
        address borrower = address(0);

        for (uint256 i = 0; i < chunks.length; i++) {
            if (borrower == address(0)) {
                borrower = chunks[i].borrower;
            }
            if (chunks[i].executed) {
                totalExecuted += chunks[i].chunkAmount;
                totalMarketImpact += chunks[i].marketImpact;
            }
        }

        totalLiquidationsCompleted++;

        emit LiquidationCompleted(liquidationId, borrower, totalExecuted, totalMarketImpact);
    }

    function _getCurrentMarketConditions() internal view returns (MarketConditions memory) {
        // Simplified market conditions - in production would use oracles and DEX data
        return MarketConditions({
            volatility: 300, // 3% volatility
            liquidity: 50000e6, // $50M liquidity
            priceImpact: 100, // 1% price impact
            timestamp: block.timestamp
        });
    }

    function _getTotalLiquidationAmount(bytes32 liquidationId) internal view returns (uint256 totalAmount) {
        LiquidationChunk[] memory chunks = liquidationChunks[liquidationId];
        
        for (uint256 i = 0; i < chunks.length; i++) {
            totalAmount += chunks[i].chunkAmount;
        }
        
        return totalAmount;
    }

    function _processChunkCompletion(
        bytes32 liquidationId,
        uint256 chunkIndex,
        uint256 chunkAmount,
        uint256 gasStart,
        uint256 originalExecutionTime
    ) internal {
        // Calculate if this was early execution (before originally scheduled time)
        bool isEarlyExecution = block.timestamp <= originalExecutionTime;
        
        // Process liquidation reward
        processLiquidationReward(msg.sender, liquidationId, chunkIndex, chunkAmount, isEarlyExecution);
        
        // Track gas usage
        uint256 gasUsed = gasStart - gasleft();
        liquidationGasUsed[liquidationId] += gasUsed;
        
        // Check if liquidation is complete
        if (_isLiquidationComplete(liquidationId)) {
            uint256 totalAmount = _getTotalLiquidationAmount(liquidationId);
            processCompletionBonus(msg.sender, liquidationId, totalAmount);
            _completeLiquidation(liquidationId);
        }
    }

    function _triggerEmergencyLiquidation(bytes32 liquidationId, string memory reason) internal {
        LiquidationChunk[] storage chunks = liquidationChunks[liquidationId];
        
        // Calculate remaining amount
        uint256 remainingAmount = 0;
        address borrower = address(0);
        
        for (uint256 i = 0; i < chunks.length; i++) {
            if (borrower == address(0)) {
                borrower = chunks[i].borrower;
            }
            if (!chunks[i].executed) {
                remainingAmount += chunks[i].chunkAmount;
                chunks[i].executed = true;
                chunks[i].executionTime = block.timestamp;
            }
        }
        
        if (remainingAmount > 0) {
            // Execute emergency liquidation through vault
            vault.emergencyLiquidate(borrower, remainingAmount);
        }
        
        // Complete the liquidation
        _completeLiquidation(liquidationId);
        
        emit EmergencyLiquidation(liquidationId, borrower, remainingAmount, reason);
    }

    // =============================================================
    //                        ADMIN FUNCTIONS
    // =============================================================

    function setShieldFiHook(address _shieldFiHook) external onlyOwner {
        shieldFiHook = _shieldFiHook;
    }

    function setAuthorizedLiquidator(address liquidator, bool authorized) external onlyOwner {
        authorizedLiquidators[liquidator] = authorized;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
} 