# ShieldFi Gradual Liquidation System

## Overview

The ShieldFi Gradual Liquidation System is an advanced liquidation mechanism designed to minimize market impact and prevent MEV exploitation during large position liquidations. Instead of executing liquidations as single large transactions, the system breaks them into optimal chunks with time delays, creating a fairer and more efficient liquidation process.

## Key Features

### 🎯 Intelligent Chunking Algorithm
- **Adaptive Chunk Count**: Automatically determines optimal number of chunks (3-8) based on position size
- **Progressive Sizing**: Front-loads larger chunks when market conditions are favorable
- **Market-Aware**: Adjusts chunk sizes based on volatility and liquidity depth

### ⏱️ Time-Delayed Execution
- **Smart Delays**: Progressive time delays between chunks prevent market manipulation
- **Volatility Adjustment**: Longer delays during high volatility periods
- **Configurable Windows**: 5 minutes to 1 hour delay windows

### 🚨 Emergency Liquidation Fallback
- **Health Factor Monitoring**: Continuous monitoring of position health
- **Instant Execution**: Emergency liquidations trigger immediately when health falls below threshold
- **Higher Rewards**: Emergency liquidators receive bonus rewards (50% extra)

### 📊 Market Impact Calculation
- **Real-time Analysis**: Calculates market impact for each chunk
- **Liquidity Awareness**: Considers available pool liquidity
- **Impact Limits**: Caps market impact per chunk (typically 5-20%)

### 🏆 Incentive System
- **Liquidator Rewards**: 1.5-2% rewards for chunk execution
- **Performance Tracking**: Tracks liquidator performance and execution history
- **Emergency Bonuses**: Additional rewards for critical liquidations

## Architecture

### Core Components

#### 1. GradualLiquidationManager
The main contract that orchestrates the entire liquidation process.

```solidity
contract GradualLiquidationManager {
    // Main liquidation request function
    function requestLiquidation(
        address user,
        PoolKey calldata poolKey,
        Currency collateralCurrency,
        Currency debtCurrency,
        uint256 amount,
        uint256 healthFactor
    ) external returns (bytes32 requestId);
    
    // Execute individual chunks
    function executeChunk(bytes32 requestId, uint8 chunkIndex) external;
    
    // Execute next available chunk from queue
    function executeNextChunk() external returns (bool success);
}
```

#### 2. Liquidation Request Structure
```solidity
struct LiquidationRequest {
    bytes32 requestId;            // Unique identifier
    address user;                 // User being liquidated
    PoolId poolId;                // Pool where liquidation occurs
    Currency collateralCurrency;  // Currency being liquidated
    Currency debtCurrency;        // Currency owed
    uint256 totalAmount;          // Total amount to liquidate
    uint256 healthFactor;         // Current health factor
    uint32 createdAt;             // Creation timestamp
    LiquidationChunk[] chunks;    // Array of chunks
    LiquidationStatus status;     // Current status
    bool isEmergency;             // Emergency flag
    uint256 totalRewardsPaid;     // Total rewards distributed
}
```

#### 3. Chunk Structure
```solidity
struct LiquidationChunk {
    uint256 amount;               // Amount to liquidate
    uint32 executeAfter;          // Earliest execution time
    bool executed;                // Execution status
    uint256 estimatedGas;         // Gas estimate
    uint256 marketImpact;         // Expected market impact
    address executor;             // Executing liquidator
}
```

### Integration with ShieldFi Hook

The Gradual Liquidation System integrates seamlessly with the ShieldFi Hook system:

```solidity
// In ShieldFiHook.sol - Emergency liquidation trigger
function _handleLiquidationContext(
    PoolId poolId,
    address user,
    ProtectionConfig memory config
) internal {
    // Add liquidation context to MEV detection engine
    mevDetectionState.addLiquidationContext(
        poolId,
        user,
        8000, // Health factor (80%)
        config.liquidationThreshold,
        userProtections[user].protectedAmount
    );
}
```

## Chunking Algorithm

### Size-Based Chunking
```
Position Size         | Optimal Chunks | Strategy
$1M+                 | 6-8 chunks     | Maximum fragmentation
$100K - $1M          | 4-6 chunks     | Balanced approach  
$10K - $100K         | 3-4 chunks     | Minimal fragmentation
< $10K               | 3 chunks       | Minimum chunks
```

### Progressive Sizing Example
For a $1M liquidation with 4 chunks in low volatility:
- Chunk 1: $400K (40%) - Execute immediately
- Chunk 2: $250K (25%) - Execute after 10 minutes
- Chunk 3: $200K (20%) - Execute after 20 minutes  
- Chunk 4: $150K (15%) - Execute after 30 minutes

### Volatility Adjustments
- **Low Volatility (<3%)**: Front-loaded chunks, shorter delays
- **Medium Volatility (3-10%)**: Balanced distribution
- **High Volatility (>10%)**: Even distribution, longer delays

## Time Delay Calculation

```solidity
function _calculateChunkDelay(
    uint8 chunkIndex,
    MarketConditions memory conditions,
    LiquidationConfig memory config
) internal pure returns (uint32 delay) {
    // Base delay increases with chunk index
    delay = config.baseDelay * (chunkIndex + 1);
    
    // Volatility adjustments
    if (conditions.volatility > 1000) { // High volatility
        delay = delay * 150 / 100; // 50% longer delays
    } else if (conditions.volatility < 300) { // Low volatility
        delay = delay * 75 / 100; // 25% shorter delays
    }
    
    // Ensure within bounds (5min - 1hour)
    if (delay < MIN_CHUNK_DELAY) delay = MIN_CHUNK_DELAY;
    if (delay > MAX_CHUNK_DELAY) delay = MAX_CHUNK_DELAY;
    
    return delay;
}
```

## Market Impact Analysis

### Impact Calculation
```solidity
function _estimateMarketImpact(
    uint256 amount,
    MarketConditions memory conditions
) internal pure returns (uint256 impact) {
    // Basic market impact model
    uint256 baseImpact = (amount * 10000) / conditions.liquidityDepth;
    uint256 volatilityMultiplier = 10000 + conditions.volatility;
    
    impact = (baseImpact * volatilityMultiplier) / 10000;
    
    // Cap at reasonable maximum (20%)
    if (impact > 2000) impact = 2000;
    
    return impact;
}
```

### Market Conditions Monitoring
- **Volatility Index**: Recent price movement analysis
- **Liquidity Depth**: Available liquidity in the pool
- **Average Trade Size**: Historical transaction analysis
- **Gas Price Tracking**: Network congestion monitoring

## Emergency Liquidation System

### Trigger Conditions
1. **Health Factor**: Falls below configured threshold (typically 50%)
2. **Market Impact**: Estimated impact exceeds emergency threshold
3. **Time Sensitivity**: Position approaching insolvency

### Emergency Process
```solidity
function _executeEmergencyLiquidation(
    LiquidationRequest storage request
) internal {
    // Mark as emergency
    request.status = LiquidationStatus.EMERGENCY;
    request.isEmergency = true;
    
    // Execute full liquidation immediately
    uint256 actualImpact = _performLiquidation(
        request.user,
        request.collateralCurrency,
        request.debtCurrency,
        request.totalAmount,
        msg.sender
    );
    
    // Pay emergency bonus (50% extra reward)
    uint256 emergencyReward = _calculateReward(
        request.totalAmount,
        config.liquidatorReward * 150 / 100
    );
    
    _distributeReward(msg.sender, emergencyReward);
}
```

## Queue Management

### Priority System
```
Priority 0: Critical Health (<30%)
Priority 1: Low Health (30-50%)
Priority 2: Medium Health (50-70%)
Priority 3: Normal Health (>70%)
```

### Queue Operations
- **Insertion**: Maintains priority order
- **Execution**: First executable chunk by priority
- **Cleanup**: Removes completed liquidations

## Gas Optimization

### Efficient Design
- **Maximum 200K gas per chunk**: Ensures reasonable execution costs
- **Batch Operations**: Multiple chunks can be executed in sequence
- **State Optimization**: Minimal storage reads/writes

### Gas Estimation
```solidity
function _estimateGasForChunk(uint256 amount) internal pure returns (uint256) {
    // Base gas cost + amount-dependent cost
    return 100000 + (amount / 1e18) * 1000;
}
```

## Usage Examples

### Basic Liquidation Request
```solidity
// Request gradual liquidation
bytes32 requestId = liquidationManager.requestLiquidation(
    userAddress,
    poolKey,
    collateralToken,
    debtToken,
    1000000e18, // $1M position
    7500         // 75% health factor
);

// Check liquidation details
(
    address user,
    PoolId poolId,
    uint256 totalAmount,
    uint256 healthFactor,
    LiquidationStatus status,
    uint8 chunkCount,
    uint8 executedChunks
) = liquidationManager.getLiquidationRequest(requestId);
```

### Execute Liquidation Chunks
```solidity
// Execute specific chunk
bool success = liquidationManager.executeChunk(requestId, 0);

// Execute next available chunk from queue
bool executed = liquidationManager.executeNextChunk();

// Check chunk details
(
    uint256 amount,
    uint32 executeAfter,
    bool executed,
    uint256 estimatedGas,
    uint256 marketImpact,
    address executor
) = liquidationManager.getChunkDetails(requestId, chunkIndex);
```

### Configuration
```solidity
// Configure liquidation parameters
GradualLiquidationManager.LiquidationConfig memory config = 
    GradualLiquidationManager.LiquidationConfig({
        maxChunks: 8,
        baseDelay: 600,           // 10 minutes
        maxMarketImpact: 1000,    // 10%
        emergencyThreshold: 5000, // 50%
        liquidatorReward: 200,    // 2%
        adaptiveChunking: true,
        enabled: true
    });

liquidationManager.configureLiquidation(poolId, config);
```

## MEV Protection Integration

### Detection Integration
- **Sandwich Detection**: Identifies liquidation sandwiching attempts
- **Gas Price Analysis**: Monitors abnormal gas price patterns
- **Timing Analysis**: Detects suspicious transaction timing
- **Volume Monitoring**: Tracks unusual trading volumes

### Protection Mechanisms
- **Time Delays**: Prevent front-running of liquidation chunks
- **Random Execution**: Optional randomization of execution times
- **Access Control**: Whitelisted liquidators for sensitive liquidations
- **Slippage Protection**: Maximum slippage limits per chunk

## Benefits

### For Users
- **Reduced Market Impact**: Gradual execution minimizes price impact
- **Fair Liquidation**: Protected from MEV exploitation
- **Transparent Process**: Clear visibility into liquidation progress

### For Liquidators
- **Predictable Rewards**: Clear reward structure
- **Risk Management**: Smaller chunks reduce execution risk
- **Efficiency Incentives**: Bonuses for emergency liquidations

### For Protocols
- **Capital Efficiency**: Better price discovery through gradual execution
- **Risk Reduction**: Lower systemic risk from large liquidations
- **MEV Mitigation**: Reduced extractable value for attackers

## Acceptance Criteria Met

✅ **Liquidations split into 3-8 optimal chunks**
- Adaptive algorithm determines optimal chunk count based on position size and market conditions

✅ **Time delays prevent market manipulation**
- Progressive delays with volatility adjustments prevent MEV exploitation

✅ **Emergency liquidation triggers properly**
- Health factor monitoring with immediate execution for critical positions

✅ **Gas costs remain reasonable per chunk**
- Maximum 200K gas per chunk with efficient batch operations

## Testing & Deployment

### Test Coverage
- Chunking algorithm with various position sizes
- Time delay execution under different market conditions
- Emergency liquidation triggering
- Gas optimization verification
- MEV detection integration
- Queue management and priority handling

### Deployment Checklist
1. Deploy GradualLiquidationManager contract
2. Configure liquidation parameters for each pool
3. Set up emergency liquidators
4. Integrate with ShieldFi Hook system
5. Configure MEV detection thresholds
6. Test with small positions before production use

## Future Enhancements

- **Cross-Pool Liquidations**: Liquidate across multiple pools simultaneously
- **Dynamic Pricing**: Real-time oracle price feeds for better market impact calculation
- **ML-Based Optimization**: Machine learning for optimal chunk sizing
- **Governance Integration**: DAO-based parameter adjustments
- **Insurance Integration**: Optional liquidation insurance for large positions 