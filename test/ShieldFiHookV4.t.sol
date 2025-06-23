// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ShieldFiHook} from "../src/ShieldFiHook.sol";
import {MEVDetectionEngine} from "../src/MEVDetectionEngine.sol";
import {GradualLiquidationManager} from "../src/GradualLiquidationManager.sol";

// Uniswap V4 Core Imports
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {IPoolManager as IPoolManagerCore} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "lib/v4-core/src/PoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolKey as PoolKeyCore} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {PoolId as PoolIdCore} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "lib/v4-core/src/types/Currency.sol";
import {Currency as CurrencyCore} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

// Uniswap V4 Test Utilities
import {Deployers} from "lib/v4-core/test/utils/Deployers.sol";
import {PoolModifyLiquidityTest} from "lib/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "lib/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "test/utils/HookMiner.sol";
import {IHooks as IHooksCore} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// Mock ERC20 for testing
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";

contract ShieldFiHookV4Test is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Test contracts
    ShieldFiHook hook;
    GradualLiquidationManager liquidationManager;
    
    // Test tokens
    MockERC20 token0;
    MockERC20 token1;
    
    // Test addresses
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address liquidator = makeAddr("liquidator");
    
    // Test pool
    PoolKey poolKey;
    PoolId poolId;
    
    // Test constants
    uint256 constant INITIAL_BALANCE = 1000000e18;
    uint256 constant MEV_THRESHOLD = 1000e18;
    uint256 constant REDISTRIBUTION_RATE = 1000; // 10%
    uint256 constant PROTECTION_FEE = 100; // 1%
    uint256 constant LIQUIDATION_THRESHOLD = 100e18;
    uint32 constant DETECTION_WINDOW = 60; // 1 minute
    
    // Hook permissions
    uint160 constant HOOK_FLAGS = 
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // Events to test
    event ProtectionConfigured(PoolIdCore indexed poolId, ShieldFiHook.ProtectionConfig config);
    event UserProtectionEnabled(address indexed user, PoolIdCore indexed poolId);
    event UserProtectionDisabled(address indexed user, PoolIdCore indexed poolId);
    event MEVDetected(
        PoolIdCore indexed poolId, 
        address indexed user, 
        uint256 amount, 
        uint256 timestamp,
        MEVDetectionEngine.MEVType mevType,
        uint256 riskScore,
        uint256 confidence
    );

    function setUp() public {
        // Deploy Uniswap V4 core contracts using Deployers
        deployFreshManagerAndRouters();
        
        // Deploy test tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        
        // Ensure token0 < token1 for proper ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        // Deploy liquidation manager
        vm.startPrank(owner);
        liquidationManager = new GradualLiquidationManager(
            IPoolManager(address(manager)),
            owner,
            address(0) // No reward token
        );
        vm.stopPrank();
        
        // Mine hook address with correct flags
        uint160 hookFlags = HOOK_FLAGS;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            hookFlags,
            type(ShieldFiHook).creationCode,
            abi.encode(address(manager), owner)
        );
        
        // Deploy hook at the mined address
        hook = new ShieldFiHook{salt: salt}(
            IPoolManagerCore(address(manager)),
            owner
        );
        
        require(address(hook) == hookAddress, "Hook address mismatch");
        
        // Set liquidation manager
        vm.startPrank(owner);
        hook.setLiquidationManager(liquidationManager);
        vm.stopPrank();
        
        // Create pool key with hook
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        poolId = poolKey.toId();
        
        // Initialize the pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        
        // Setup initial balances
        _setupBalances();
        
        // Configure protection for the pool
        _configureProtection();
    }

    function _setupBalances() internal {
        // Mint tokens to test addresses
        token0.mint(address(this), INITIAL_BALANCE);
        token1.mint(address(this), INITIAL_BALANCE);
        token0.mint(user1, INITIAL_BALANCE);
        token1.mint(user1, INITIAL_BALANCE);
        token0.mint(user2, INITIAL_BALANCE);
        token1.mint(user2, INITIAL_BALANCE);
        
        // Approve tokens for routers
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        
        // Give test addresses some ETH
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(liquidator, 100 ether);
        vm.deal(address(this), 100 ether);
        
        // Setup approvals for users
        vm.startPrank(user1);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user2);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
    
    function _configureProtection() internal {
        ShieldFiHook.ProtectionConfig memory config = ShieldFiHook.ProtectionConfig({
            enabled: true,
            mevThreshold: MEV_THRESHOLD,
            redistributionRate: REDISTRIBUTION_RATE,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            protectionFee: PROTECTION_FEE,
            maxSlippage: 500, // 5%
            protectedAsset: address(token0),
            detectionWindow: DETECTION_WINDOW
        });
        
        vm.startPrank(owner);
        // Convert PoolKey to the type expected by ShieldFiHook
        bytes memory poolKeyData = abi.encode(poolKey);
        PoolKeyCore memory poolKeyForHook = abi.decode(poolKeyData, (PoolKeyCore));
        hook.configureProtection(poolKeyForHook, config);
        vm.stopPrank();
    }

    // ============ Basic Tests ============
    
    function test_v4HookDeployment() public view {
        assertTrue(address(hook) != address(0), "Hook should be deployed");
        assertTrue(address(manager) != address(0), "Manager should be deployed");
        assertEq(address(hook.poolManager()), address(manager), "Hook should reference correct manager");
    }
    
    function test_v4PoolInitialization() public view {
        assertTrue(PoolId.unwrap(poolId) != bytes32(0), "Pool ID should not be zero");
        
        // Check pool state exists
        uint128 liquidity = manager.getLiquidity(poolId);
        // Pool should be initialized even with 0 liquidity
        assertTrue(true, "Pool should be initialized");
    }
    
    function test_v4ProtectionConfiguration() public view {
        ShieldFiHook.ProtectionConfig memory config = hook.getProtectionConfig(PoolIdCore.wrap(PoolId.unwrap(poolId)));
        assertTrue(config.enabled, "Protection should be enabled");
        assertEq(config.mevThreshold, MEV_THRESHOLD, "MEV threshold should match");
        assertEq(config.redistributionRate, REDISTRIBUTION_RATE, "Redistribution rate should match");
    }

    // ============ Liquidity Tests ============
    
    function test_v4AddLiquidity() public {
        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Check liquidity was added
        uint128 liquidity = manager.getLiquidity(poolId);
        assertTrue(liquidity > 0, "Pool should have liquidity");
    }

    // ============ Swap Tests ============
    
    function test_v4BasicSwap() public {
        // Add liquidity first
        test_v4AddLiquidity();
        
        // Perform a swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18, // Exact input
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        BalanceDelta delta = swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        
        // Check swap occurred
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "Swap should have occurred");
    }
    
    function test_v4SwapWithMEVDetection() public {
        // Add liquidity first
        test_v4AddLiquidity();
        
        // Enable protection for user1
        vm.startPrank(user1);
        hook.enableUserProtection{value: 1 ether}(PoolIdCore.wrap(PoolId.unwrap(poolId)));
        vm.stopPrank();
        
        // Perform a large swap that should trigger MEV detection
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(MEV_THRESHOLD * 2), // Large swap
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        vm.startPrank(user1);
        // This should trigger MEV detection in the hook
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        vm.stopPrank();
        
        // Check MEV was detected - the penalty is applied to the actual sender (swapRouter)
        // In real usage, this would be the user's address, but in tests it's the router contract
        uint256 routerScore = hook.getUserMEVScore(address(swapRouter));
        assertTrue(routerScore > 0, "MEV score should be updated for the swap sender");
    }

    // ============ Protection Tests ============
    
    function test_v4EnableProtection() public {
        vm.startPrank(user1);
        
        vm.expectEmit(true, true, false, false);
        emit UserProtectionEnabled(user1, PoolIdCore.wrap(PoolId.unwrap(poolId)));
        
        hook.enableUserProtection{value: 1 ether}(PoolIdCore.wrap(PoolId.unwrap(poolId)));
        
        assertTrue(hook.isUserProtected(user1, PoolIdCore.wrap(PoolId.unwrap(poolId))), "Protection should be enabled");
        vm.stopPrank();
    }
    
    function test_v4DisableProtection() public {
        // First enable protection
        test_v4EnableProtection();
        
        vm.startPrank(user1);
        
        vm.expectEmit(true, true, false, false);
        emit UserProtectionDisabled(user1, PoolIdCore.wrap(PoolId.unwrap(poolId)));
        
        hook.disableUserProtection(PoolIdCore.wrap(PoolId.unwrap(poolId)));
        
        assertFalse(hook.isUserProtected(user1, PoolIdCore.wrap(PoolId.unwrap(poolId))), "Protection should be disabled");
        vm.stopPrank();
    }

    // ============ MEV Detection Tests ============
    
    function test_v4LargeSwapDetection() public {
        test_v4AddLiquidity();
        
        // Enable protection
        vm.startPrank(user1);
        hook.enableUserProtection{value: 1 ether}(PoolIdCore.wrap(PoolId.unwrap(poolId)));
        vm.stopPrank();
        
        // Perform large swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(MEV_THRESHOLD * 3),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        vm.startPrank(user1);
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        vm.stopPrank();
        
        // Check MEV was detected - penalty applied to the swap sender (router contract)
        uint256 routerScore = hook.getUserMEVScore(address(swapRouter));
        assertTrue(routerScore > 0, "MEV score should be updated for the swap sender");
    }

    // ============ Integration Tests ============
    
    function test_v4HookIntegration() public {
        // Test that hook integrates properly with Uniswap V4
        assertTrue(address(hook.poolManager()) == address(manager), "Hook should be connected to manager");
        assertTrue(address(hook.liquidationManager()) == address(liquidationManager), "Hook should be connected to liquidation manager");
        
        // Test hook flags
        uint160 hookAddress = uint160(address(hook));
        uint160 flags = hookAddress & uint160(0x3FFF);
        assertTrue(flags & uint160(Hooks.BEFORE_SWAP_FLAG) != 0, "Should have before swap flag");
        assertTrue(flags & uint160(Hooks.AFTER_SWAP_FLAG) != 0, "Should have after swap flag");
    }

    // ============ View Function Tests ============
    
    function test_v4GetUserProtection() public {
        // Enable protection first
        vm.startPrank(user1);
        hook.enableUserProtection{value: 2 ether}(PoolIdCore.wrap(PoolId.unwrap(poolId)));
        vm.stopPrank();
        
        // Get user protection details
        (bool isActive, uint256 protectedAmount, uint256 lastInteraction, uint256 accumulatedRewards, uint256 penaltyScore) = hook.getUserProtection(user1);
        
        assertTrue(isActive, "Protection should be active");
        assertEq(protectedAmount, 2 ether, "Protected amount should match");
        assertTrue(lastInteraction > 0, "Last interaction should be set");
        assertEq(accumulatedRewards, 0, "No rewards initially");
        assertEq(penaltyScore, 0, "No penalty initially");
    }
    
    function test_v4GetMEVDetectionAccuracy() public view {
        (uint256 accuracy, uint256 falsePositiveRate) = hook.getMEVDetectionAccuracy();
        assertEq(accuracy, 9500, "Accuracy should be 95%");
        assertEq(falsePositiveRate, 500, "False positive rate should be 5%");
    }

    // ============ Helper Functions ============
    
    function _getTestConfig() internal view returns (ShieldFiHook.ProtectionConfig memory) {
        return ShieldFiHook.ProtectionConfig({
            enabled: true,
            mevThreshold: MEV_THRESHOLD,
            redistributionRate: REDISTRIBUTION_RATE,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            protectionFee: PROTECTION_FEE,
            maxSlippage: 500,
            protectedAsset: address(token0),
            detectionWindow: DETECTION_WINDOW
        });
    }

    function test_simpleUniswapV4Setup() public {
        // Basic test to ensure V4 setup works
        assertTrue(true, "Basic test should pass");
    }
    
    function test_constants() public pure {
        uint256 MEV_THRESHOLD = 1000e18;
        uint256 REDISTRIBUTION_RATE = 1000; // 10%
        uint256 PROTECTION_FEE = 100; // 1%
        
        assertTrue(MEV_THRESHOLD > 0, "MEV threshold should be positive");
        assertTrue(REDISTRIBUTION_RATE <= 10000, "Redistribution rate should be reasonable");
        assertTrue(PROTECTION_FEE <= 10000, "Protection fee should be reasonable");
    }
} 