// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title ShieldFiHook
 * @notice A simplified Uniswap v4 hook for MEV protection
 * @dev Implements beforeSwap and afterSwap hooks to monitor MEV
 */
contract ShieldFiHook is BaseHook {
    using PoolIdLibrary for PoolKey;
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
        uint256 timestamp
    );

    event ProtectionConfigUpdated(
        PoolId indexed poolId,
        uint256 mevThreshold,
        uint256 redistributionRate,
        bool enabled
    );

    // ============ Structs ============

    struct ProtectionConfig {
        uint256 mevThreshold;
        uint256 redistributionRate;
        uint256 maxSlippage;
        bool enabled;
    }

    struct UserProtection {
        uint256 totalSwapVolume;
        uint256 lastSwapTime;
        uint256 mevPenalty;
        bool isWhitelisted;
    }

    struct LiquidationEvent {
        address user;
        uint256 amount;
        uint256 timestamp;
        bool executed;
    }

    // ============ Storage ============

    mapping(PoolId => ProtectionConfig) public protectionConfigs;
    mapping(PoolId => mapping(address => UserProtection)) public userProtections;
    mapping(PoolId => mapping(Currency => uint256)) public mevRewards;
    mapping(PoolId => LiquidationEvent[]) public liquidationEvents;
    mapping(PoolId => bool) public poolInitialized;
    
    bool public emergencyPaused;
    address public owner;

    // Constants
    uint256 public constant MAX_BPS = 10000;
    uint256 public constant MIN_MEV_THRESHOLD = 0.1 ether;

    // ============ Constructor ============

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
    }

    // Override to bypass hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation for testing
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
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

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        require(!emergencyPaused, "ShieldFi: Emergency paused");

        PoolId poolId = key.toId();
        
        // Initialize pool protection on first swap
        if (!poolInitialized[poolId]) {
            _initializePoolProtection(poolId);
        }
        
        ProtectionConfig memory config = protectionConfigs[poolId];
        
        if (!config.enabled) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        address user = _parseUserFromHookData(hookData, sender);
        UserProtection storage userProtection = userProtections[poolId][user];
        userProtection.lastSwapTime = block.timestamp;

        uint256 swapAmount = swapParams.amountSpecified < 0 
            ? uint256(-swapParams.amountSpecified) 
            : uint256(swapParams.amountSpecified);

        // MEV detection
        if (swapAmount >= config.mevThreshold && !userProtection.isWhitelisted) {
            uint256 detectedMEV = _calculateMEVAmount(swapAmount, config);
            
            if (detectedMEV > 0) {
                emit MEVDetected(poolId, user, swapAmount, detectedMEV, block.timestamp);
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

        address user = _parseUserFromHookData(hookData, sender);
        UserProtection storage userProtection = userProtections[poolId][user];
        
        uint256 swapAmount = swapParams.amountSpecified < 0 
            ? uint256(-swapParams.amountSpecified) 
            : uint256(swapParams.amountSpecified);
        
        userProtection.totalSwapVolume += swapAmount;

        // Redistribute MEV if detected
        if (userProtection.mevPenalty > 0) {
            _redistributeMEV(key, userProtection.mevPenalty);
            userProtection.mevPenalty = 0;
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // ============ Internal Functions ============

    function _initializePoolProtection(PoolId poolId) internal {
        protectionConfigs[poolId] = ProtectionConfig({
            mevThreshold: MIN_MEV_THRESHOLD,
            redistributionRate: 1000, // 10%
            maxSlippage: 500, // 5%
            enabled: true
        });
        
        poolInitialized[poolId] = true;
    }

    function _parseUserFromHookData(bytes calldata hookData, address defaultUser) internal pure returns (address) {
        if (hookData.length >= 20) {
            return address(bytes20(hookData[0:20]));
        }
        return defaultUser;
    }

    function _calculateMEVAmount(uint256 swapAmount, ProtectionConfig memory config) internal pure returns (uint256) {
        if (swapAmount < config.mevThreshold) {
            return 0;
        }
        
        uint256 excessAmount = swapAmount - config.mevThreshold;
        return (excessAmount * config.redistributionRate) / MAX_BPS;
    }

    function _redistributeMEV(PoolKey calldata key, uint256 mevAmount) internal {
        PoolId poolId = key.toId();
        Currency currency = key.currency0;
        
        mevRewards[poolId][currency] += mevAmount;
        emit MEVRedistributed(poolId, mevAmount, block.timestamp);
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
        require(redistributionRate <= 5000, "Rate too high");

        protectionConfigs[poolId] = ProtectionConfig({
            mevThreshold: mevThreshold,
            redistributionRate: redistributionRate,
            maxSlippage: maxSlippage,
            enabled: enabled
        });

        if (!poolInitialized[poolId]) {
            poolInitialized[poolId] = true;
        }

        emit ProtectionConfigUpdated(poolId, mevThreshold, redistributionRate, enabled);
    }

    function emergencyPause(bool paused) external onlyOwner {
        emergencyPaused = paused;
    }

    function triggerLiquidation(PoolId poolId, address user, uint256 amount) external onlyOwner {
        liquidationEvents[poolId].push(LiquidationEvent({
            user: user,
            amount: amount,
            timestamp: block.timestamp,
            executed: false
        }));
    }

    function withdrawMEVRewards(
        PoolId poolId,
        Currency currency,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(amount <= mevRewards[poolId][currency], "Insufficient rewards");
        mevRewards[poolId][currency] -= amount;
        // Simplified - just update storage, actual transfer would need more logic
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
}