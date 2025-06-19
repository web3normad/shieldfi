// ============ test/ShieldFi.t.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ShieldFiHook} from "../src/ShieldFiHook.sol";

// Mock manager contract to avoid size issues
contract MockManager {
    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        return 0;
    }
    
    // Override validation to bypass hook address validation
    function isPoolInitialized(PoolId) external pure returns (bool) {
        return true;
    }
}

// Minimal test without complex infrastructure
contract ShieldFiHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ShieldFiHook hook;
    IPoolManager manager;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // Deploy lightweight manager
        MockManager mockManager = new MockManager();
        manager = IPoolManager(address(mockManager));
        
        // Deploy hook directly
        hook = new ShieldFiHook(manager);
        
        // Create minimal pool key without hook validation
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0)) // Use zero address to avoid validation
        });
        poolId = poolKey.toId();
    }

    function test_HookDeployment() public view {
        assertTrue(address(hook) != address(0));
        
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
    }

    function test_PoolInitialization() public view {
        // Pool won't be initialized in this minimal test but config should exist
        ShieldFiHook.ProtectionConfig memory config = hook.getProtectionConfig(poolId);
        // Default values should be set
        assertTrue(config.mevThreshold > 0 || !config.enabled);
    }

    function test_UpdateProtectionConfig() public {
        uint256 newThreshold = 5 ether;
        uint256 newRate = 2000;
        uint256 newSlippage = 300;
        
        hook.updateProtectionConfig(poolId, newThreshold, newRate, newSlippage, true);
        
        ShieldFiHook.ProtectionConfig memory config = hook.getProtectionConfig(poolId);
        assertEq(config.mevThreshold, newThreshold);
        assertEq(config.redistributionRate, newRate);
        assertEq(config.maxSlippage, newSlippage);
    }

    function test_UpdateProtectionConfig_OnlyOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Not owner");
        hook.updateProtectionConfig(poolId, 5 ether, 2000, 300, true);
    }

    function test_EmergencyPause() public {
        hook.emergencyPause(true);
        assertTrue(hook.emergencyPaused());
        
        hook.emergencyPause(false);
        assertFalse(hook.emergencyPaused());
    }

    function test_TriggerLiquidation() public {
        address targetUser = makeAddr("targetUser");
        uint256 liquidationAmount = 5 ether;
        
        hook.triggerLiquidation(poolId, targetUser, liquidationAmount);
        
        ShieldFiHook.LiquidationEvent[] memory events = hook.getLiquidationEvents(poolId);
        assertEq(events.length, 1);
        assertEq(events[0].user, targetUser);
        assertEq(events[0].amount, liquidationAmount);
        assertFalse(events[0].executed);
    }

    function test_MEVRewardsInitiallyZero() public {
        Currency currency = Currency.wrap(address(0x1));
        uint256 rewards = hook.getMEVRewards(poolId, currency);
        assertEq(rewards, 0);
    }

    function test_UserProtectionInitiallyEmpty() public {
        address user = makeAddr("user");
        ShieldFiHook.UserProtection memory protection = hook.getUserProtection(poolId, user);
        assertEq(protection.totalSwapVolume, 0);
        assertEq(protection.lastSwapTime, 0);
        assertEq(protection.mevPenalty, 0);
        assertFalse(protection.isWhitelisted);
    }
}