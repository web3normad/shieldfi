// ============ test/ShieldFi.t.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ShieldFiHook} from "../src/ShieldFiHook.sol";
import {Fixtures, TestToken} from "./utils/Fixtures.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract ShieldFiHookTest is Test, Fixtures, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ShieldFiHook hook;
    PoolKey poolKey;
    PoolId poolId;
    
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant LARGE_SWAP_AMOUNT = 10 ether;
    uint256 constant SMALL_SWAP_AMOUNT = 1 ether;
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function setUp() public {
        // Deploy pool manager and routers
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        
        // Mine hook address with correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        ) ^ (0x4444 << 144);
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(ShieldFiHook).creationCode,
            abi.encode(address(manager))
        );
        
        // Deploy hook
        hook = new ShieldFiHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == hookAddress, "Hook address mismatch");
        
        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(currency0)),
            currency1: Currency.wrap(address(currency1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        
        // Initialize pool
        manager.initialize(poolKey, SQRT_RATIO_1_1);
        
        // Setup test accounts
        _setupTestAccounts();
        
        // Add initial liquidity
        _addInitialLiquidity();
    }

    function _setupTestAccounts() internal {
        address[2] memory accounts = [alice, bob];
        
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            
            // Mint tokens using TestToken's mint function
            currency0.mint(account, INITIAL_BALANCE);
            currency1.mint(account, INITIAL_BALANCE);
            
            // Give ETH
            vm.deal(account, 100 ether);
            
            // Approve
            vm.startPrank(account);
            currency0.approve(address(manager), type(uint256).max);
            currency1.approve(address(manager), type(uint256).max);
            currency0.approve(address(swapRouter), type(uint256).max);
            currency1.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _addInitialLiquidity() internal {
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);
        
        uint256 liquidityAmount = 100 ether;
        
        // Use ModifyLiquidityParams from PoolOperation.sol and call manager.unlock
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(liquidityAmount),
            salt: bytes32(0)
        });
        
        bytes memory data = abi.encode(poolKey, params);
        manager.unlock(data);
    }

    // IUnlockCallback implementation
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Unauthorized");
        
        (PoolKey memory key, ModifyLiquidityParams memory params) = abi.decode(data, (PoolKey, ModifyLiquidityParams));
        
        // Add liquidity
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");
        
        // Settle the deltas
        if (delta.amount0() != 0) {
            if (delta.amount0() > 0) {
                // We owe the pool
                currency0.transfer(address(manager), uint256(int256(delta.amount0())));
                manager.settle();
            } else {
                // Pool owes us
                manager.take(key.currency0, address(this), uint256(int256(-delta.amount0())));
            }
        }
        
        if (delta.amount1() != 0) {
            if (delta.amount1() > 0) {
                // We owe the pool
                currency1.transfer(address(manager), uint256(int256(delta.amount1())));
                manager.settle();
            } else {
                // Pool owes us
                manager.take(key.currency1, address(this), uint256(int256(-delta.amount1())));
            }
        }
        
        return "";
    }

    // ============ Basic Tests ============

    function test_HookDeployment() public view {
        assertTrue(address(hook) != address(0));
        
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
    }

    function test_PoolInitialization() public {
        assertTrue(hook.isPoolInitialized(poolId));
        
        ShieldFiHook.ProtectionConfig memory config = hook.getProtectionConfig(poolId);
        assertEq(config.mevThreshold, hook.MIN_MEV_THRESHOLD());
        assertTrue(config.enabled);
    }

    function test_BasicSwap() public {
        uint256 swapAmount = SMALL_SWAP_AMOUNT;
        
        vm.startPrank(alice);
        
        bytes memory hookData = abi.encode(alice);
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            hookData
        );
        
        vm.stopPrank();
        
        ShieldFiHook.UserProtection memory userProtection = hook.getUserProtection(poolId, alice);
        assertEq(userProtection.totalSwapVolume, swapAmount);
    }

    function test_MEVDetection() public {
        uint256 largeSwapAmount = LARGE_SWAP_AMOUNT;
        
        vm.startPrank(alice);
        bytes memory hookData = abi.encode(alice);
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(largeSwapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            hookData
        );
        
        vm.stopPrank();
        
        ShieldFiHook.UserProtection memory userProtection = hook.getUserProtection(poolId, alice);
        assertGt(userProtection.mevPenalty, 0);
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
        vm.prank(alice);
        vm.expectRevert();
        hook.updateProtectionConfig(poolId, 5 ether, 2000, 300, true);
    }

    function test_EmergencyPause() public {
        hook.emergencyPause(true);
        assertTrue(hook.emergencyPaused());
        
        vm.startPrank(alice);
        bytes memory hookData = abi.encode(alice);
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        vm.expectRevert("ShieldFi: Emergency paused");
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(SMALL_SWAP_AMOUNT),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            hookData
        );
        
        vm.stopPrank();
    }

    function test_WithdrawMEVRewards() public {
        // Generate MEV rewards first
        _generateMEVRewards();
        
        Currency currency = Currency.wrap(address(currency0));
        uint256 rewardAmount = hook.getMEVRewards(poolId, currency);
        
        if (rewardAmount > 0) {
            uint256 initialBalance = currency0.balanceOf(address(this));
            hook.withdrawMEVRewards(poolId, currency, address(this), rewardAmount);
            assertEq(currency0.balanceOf(address(this)), initialBalance + rewardAmount);
        }
    }

    function test_TriggerLiquidation() public {
        address targetUser = alice;
        uint256 liquidationAmount = 5 ether;
        
        hook.triggerLiquidation(poolId, targetUser, liquidationAmount);
        
        ShieldFiHook.LiquidationEvent[] memory events = hook.getLiquidationEvents(poolId);
        assertEq(events.length, 1);
        assertEq(events[0].user, targetUser);
        assertEq(events[0].amount, liquidationAmount);
        assertFalse(events[0].executed);
    }

    function _generateMEVRewards() internal {
        vm.startPrank(alice);
        bytes memory hookData = abi.encode(alice);
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(LARGE_SWAP_AMOUNT),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            hookData
        );
        
        vm.stopPrank();
    }
}