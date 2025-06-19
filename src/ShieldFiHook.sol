// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ✅ CORRECTED IMPORTS
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ShieldFiHook
 * @notice A Uniswap v4 hook that provides MEV protection through detection and redistribution
 * @dev Implements beforeSwap and afterSwap hooks to monitor and redistribute MEV
 */
contract ShieldFiHook is BaseHook, ReentrancyGuard, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    // ============ Events ============

    event MEVDetected(
        PoolId indexed poolId,
        address indexed user,
        uint256 swapAmount,
        uint256 detectedMEV,
        uint256 timestamp
    );

    event MEVRedistributed(
        PoolId indexed poolId,
        uint256 amount,
        uint256 lpReward,
        uint256 timestamp
    );

    event ProtectionConfigUpdated(
        PoolId indexed poolId,
        uint256 mevThreshold,
        uint256 redistributionRate,
        bool enabled
    );

    event LiquidationTriggered(
        PoolId indexed poolId,
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    event EmergencyPaused(bool paused);

    event PoolInitialized(PoolId indexed poolId, uint256 timestamp);

    // ============ Structs ============

    struct ProtectionConfig {
        uint256 mevThreshold;           // Minimum swap size to trigger MEV detection (in wei)
        uint256 redistributionRate;     // Percentage of MEV to redistribute (basis points, max 10000)
        uint256 maxSlippage;            // Maximum allowed slippage (basis points)
        bool enabled;                   // Whether protection is enabled for this pool
        uint256 lastUpdateTime;         // Last time config was updated
    }

    struct UserProtection {
        uint256 totalSwapVolume;        // Total swap volume by user
        uint256 lastSwapTime;           // Timestamp of last swap
        uint256 mevPenalty;             // Accumulated MEV penalty
        bool isWhitelisted;             // Whether user is whitelisted from MEV detection
    }

    struct LiquidationEvent {
        address user;                   // User being liquidated
        uint256 amount;                 // Amount being liquidated
        uint256 timestamp;              // When liquidation occurred
        bool executed;                  // Whether liquidation was executed
    }

    // ============ Storage ============

    // Pool-specific protection configurations
    mapping(PoolId => ProtectionConfig) public protectionConfigs;
    
    // User protection data per pool
    mapping(PoolId => mapping(address => UserProtection)) public userProtections;
    
    // MEV redistribution pool balances
    mapping(PoolId => mapping(Currency => uint256)) public mevRewards;
    
    // Liquidation events
    mapping(PoolId => LiquidationEvent[]) public liquidationEvents;
    
    // Track which pools have been initialized
    mapping(PoolId => bool) public poolInitialized;
    
    // Global emergency pause
    bool public emergencyPaused;

    // Constants
    uint256 public constant MAX_BPS = 10000;
    uint256 public constant MEV_DETECTION_WINDOW = 1 minutes;
    uint256 public constant MIN_MEV_THRESHOLD = 0.1 ether;
    uint256 public constant MAX_REDISTRIBUTION_RATE = 5000; // 50%

    // ============ Constructor ============

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) Ownable(msg.sender) {
        // Constructor sets up the hook with proper pool manager reference
    }

    // ============ Hook Permissions ============
    // 🔥 KEY FIX: Remove afterInitialize from permissions since we don't override it

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false, // ✅ Set to false since we don't implement it
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Hook Functions ============
    // 🔥 REMOVED _afterInitialize - it doesn't exist in BaseHook to override!

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (emergencyPaused) {
            revert("ShieldFi: Emergency paused");
        }

        PoolId poolId = key.toId();
        
        // 🔥 LAZY INITIALIZATION: Initialize pool protection on first swap if not already done
        if (!poolInitialized[poolId]) {
            _initializePoolProtection(poolId);
        }
        
        ProtectionConfig memory config = protectionConfigs[poolId];
        
        if (!config.enabled) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Parse user address from hook data
        address user = _parseUserFromHookData(hookData, sender);
        
        // Update user protection data
        UserProtection storage userProtection = userProtections[poolId][user];
        userProtection.lastSwapTime = block.timestamp;

        // Check for MEV detection triggers
        uint256 swapAmountSpecified = swapParams.amountSpecified < 0 
            ? uint256(-swapParams.amountSpecified) 
            : uint256(swapParams.amountSpecified);

        bool largeTrade = swapAmountSpecified >= config.mevThreshold;
        bool quickSequence = block.timestamp - userProtection.lastSwapTime < MEV_DETECTION_WINDOW;
        
        // Detect potential MEV
        if (largeTrade && !userProtection.isWhitelisted) {
            uint256 detectedMEV = _calculateMEVAmount(swapAmountSpecified, config);
            
            if (detectedMEV > 0) {
                emit MEVDetected(poolId, user, swapAmountSpecified, detectedMEV, block.timestamp);
                
                // Apply MEV penalty
                userProtection.mevPenalty += detectedMEV;
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (emergencyPaused) {
            return (BaseHook.afterSwap.selector, 0);
        }

        PoolId poolId = key.toId();
        ProtectionConfig memory config = protectionConfigs[poolId];
        
        if (!config.enabled) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Parse user address from hook data
        address user = _parseUserFromHookData(hookData, sender);
        
        // Update user swap volume
        UserProtection storage userProtection = userProtections[poolId][user];
        uint256 swapAmountSpecified = swapParams.amountSpecified < 0 
            ? uint256(-swapParams.amountSpecified) 
            : uint256(swapParams.amountSpecified);
        
        userProtection.totalSwapVolume += swapAmountSpecified;

        // Calculate and redistribute MEV if detected
        if (userProtection.mevPenalty > 0) {
            _redistributeMEV(key, userProtection.mevPenalty, delta);
            userProtection.mevPenalty = 0; // Reset penalty after redistribution
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // ============ Internal Functions ============

    // 🔥 NEW: Lazy initialization function called on first swap
    function _initializePoolProtection(PoolId poolId) internal {
        protectionConfigs[poolId] = ProtectionConfig({
            mevThreshold: MIN_MEV_THRESHOLD,
            redistributionRate: 1000, // 10%
            maxSlippage: 500, // 5%
            enabled: true,
            lastUpdateTime: block.timestamp
        });
        
        poolInitialized[poolId] = true;
        emit PoolInitialized(poolId, block.timestamp);
    }

    function _parseUserFromHookData(bytes calldata hookData, address defaultUser) internal pure returns (address) {
        if (hookData.length >= 20) {
            return address(bytes20(hookData[0:20]));
        }
        return defaultUser;
    }

    function _calculateMEVAmount(uint256 swapAmount, ProtectionConfig memory config) internal pure returns (uint256) {
        // Simple MEV calculation based on swap size and threshold
        if (swapAmount < config.mevThreshold) {
            return 0;
        }
        
        // Calculate MEV as percentage of amount above threshold
        uint256 excessAmount = swapAmount - config.mevThreshold;
        return (excessAmount * config.redistributionRate) / MAX_BPS;
    }

    function _redistributeMEV(
        PoolKey calldata key,
        uint256 mevAmount,
        BalanceDelta delta
    ) internal {
        PoolId poolId = key.toId();
        
        // Determine which currency to use based on delta
        Currency currency = delta.amount0() != 0 ? key.currency0 : key.currency1;
        
        // Add to MEV rewards pool
        mevRewards[poolId][currency] += mevAmount;
        
        emit MEVRedistributed(poolId, mevAmount, mevAmount, block.timestamp);
    }

    // ============ Admin Functions ============

    function updateProtectionConfig(
        PoolId poolId,
        uint256 mevThreshold,
        uint256 redistributionRate,
        uint256 maxSlippage,
        bool enabled
    ) external onlyOwner {
        require(mevThreshold >= MIN_MEV_THRESHOLD, "Threshold too low");
        require(redistributionRate <= MAX_REDISTRIBUTION_RATE, "Rate too high");
        require(maxSlippage <= MAX_BPS, "Invalid slippage");

        protectionConfigs[poolId] = ProtectionConfig({
            mevThreshold: mevThreshold,
            redistributionRate: redistributionRate,
            maxSlippage: maxSlippage,
            enabled: enabled,
            lastUpdateTime: block.timestamp
        });

        // Mark pool as initialized if not already
        if (!poolInitialized[poolId]) {
            poolInitialized[poolId] = true;
            emit PoolInitialized(poolId, block.timestamp);
        }

        emit ProtectionConfigUpdated(poolId, mevThreshold, redistributionRate, enabled);
    }

    function setUserWhitelist(
        PoolId poolId,
        address user,
        bool whitelisted
    ) external onlyOwner {
        userProtections[poolId][user].isWhitelisted = whitelisted;
    }

    function emergencyPause(bool paused) external onlyOwner {
        emergencyPaused = paused;
        emit EmergencyPaused(paused);
    }

    function withdrawMEVRewards(
        PoolId poolId,
        Currency currency,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(amount <= mevRewards[poolId][currency], "Insufficient rewards");
        
        mevRewards[poolId][currency] -= amount;
        
        if (currency.isAddressZero()) {
            payable(to).transfer(amount);
        } else {
            IERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }

    // ============ View Functions ============

    function getProtectionConfig(PoolId poolId) external view returns (ProtectionConfig memory) {
        return protectionConfigs[poolId];
    }

    function getUserProtection(PoolId poolId, address user) external view returns (UserProtection memory) {
        return userProtections[poolId][user];
    }

    function getMEVRewards(PoolId poolId, Currency currency) external view returns (uint256) {
        return mevRewards[poolId][currency];
    }

    function getLiquidationEvents(PoolId poolId) external view returns (LiquidationEvent[] memory) {
        return liquidationEvents[poolId];
    }

    function isPoolInitialized(PoolId poolId) external view returns (bool) {
        return poolInitialized[poolId];
    }

    // ============ Liquidation Functions ============

    function triggerLiquidation(
        PoolId poolId,
        address user,
        uint256 amount
    ) external onlyOwner {
        liquidationEvents[poolId].push(LiquidationEvent({
            user: user,
            amount: amount,
            timestamp: block.timestamp,
            executed: false
        }));

        emit LiquidationTriggered(poolId, user, amount, block.timestamp);
    }

    function executeLiquidation(
        PoolId poolId,
        uint256 eventIndex
    ) external onlyOwner nonReentrant {
        require(eventIndex < liquidationEvents[poolId].length, "Invalid event index");
        
        LiquidationEvent storage liquidationEvent = liquidationEvents[poolId][eventIndex];
        require(!liquidationEvent.executed, "Already executed");
        
        liquidationEvent.executed = true;
        
        // Implementation would depend on specific liquidation logic
        // This is a placeholder for the actual liquidation mechanism
    }

    // ============ Emergency Recovery ============

    function emergencyWithdraw(
        Currency currency,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(emergencyPaused, "Only during emergency");
        
        if (currency.isAddressZero()) {
            payable(to).transfer(amount);
        } else {
            IERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }

    // Receive function for ETH
    receive() external payable {}
}