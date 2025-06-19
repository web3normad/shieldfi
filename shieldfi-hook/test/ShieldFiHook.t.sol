// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.24;

// import "forge-std/Test.sol";
// import "forge-std/console.sol";

// import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
// import {Hooks} from "v4-core/src/libraries/Hooks.sol";
// import {TickMath} from "v4-core/src/libraries/TickMath.sol";
// import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey} from "v4-core/src/types/PoolKey.sol";
// import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
// import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
// import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
// import {Deployers} from "v4-core/test/utils/Deployers.sol";

// import "../src/ShieldFiHook.sol";
// import "../src/MEVDetector.sol";
// import "../src/CircleUSDCVault.sol";
// import "../src/GradualLiquidator.sol";

// contract ShieldFiHookTest is Test, Deployers {
//     using PoolIdLibrary for PoolKey;
//     using CurrencyLibrary for Currency;

//     ShieldFiHook hook;
//     MEVDetector mevDetector;
//     CircleUSDCVault vault;
//     GradualLiquidator liquidator;
    
//     PoolKey poolKey;
//     PoolId poolId;

//     // Mock USDC token
//     MockERC20 usdc;
//     MockERC20 weth;

//     address alice = makeAddr("alice");
//     address bob = makeAddr("bob");
//     address liquidatorBot = makeAddr("liquidatorBot");

//     function setUp() public {
//         // Deploy v4 core contracts
//         deployFreshManagerAndRouters();
        
//         // Deploy mock tokens
//         usdc = new MockERC20("USD Coin", "USDC", 6);
//         weth = new MockERC20("Wrapped Ether", "WETH", 18);

//         // Deploy MEV Detector
//         mevDetector = new MEVDetector();

//         // Deploy USDC Vault
//         vault = new CircleUSDCVault(address(usdc));

//         // Deploy Gradual Liquidator
//         liquidator = new GradualLiquidator(
//             address(vault),
//             address(mevDetector),
//             address(usdc)
//         );

//         // Deploy ShieldFi Hook
//         uint160 flags = uint160(
//             Hooks.BEFORE_SWAP_FLAG | 
//             Hooks.AFTER_SWAP_FLAG | 
//             Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
//             Hooks.AFTER_ADD_LIQUIDITY_FLAG |
//             Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
//             Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
//         );
        
//         (address hookAddress, bytes32 salt) = HookMiner.find(
//             address(this),
//             flags,
//             type(ShieldFiHook).creationCode,
//             abi.encode(
//                 address(manager),
//                 address(usdc),
//                 address(this) // emergency admin
//             )
//         );

//         hook = new ShieldFiHook{salt: salt}(
//             IPoolManager(address(manager)),
//             address(usdc),
//             address(this)
//         );
//         require(address(hook) == hookAddress, "Hook address mismatch");

//         // Set up integrations
//         hook.setMEVDetector(address(mevDetector));
//         hook.setGradualLiquidator(address(liquidator));
//         hook.setUSDCVault(address(vault));

//         vault.setShieldFiHook(address(hook));
//         liquidator.setShieldFiHook(address(hook));
//         liquidator.setAuthorizedLiquidator(liquidatorBot, true);

//         // Create pool
//         poolKey = PoolKey({
//             currency0: Currency.wrap(address(usdc)),
//             currency1: Currency.wrap(address(weth)),
//             fee: 3000,
//             tickSpacing: 60,
//             hooks: IHooks(address(hook))
//         });
//         poolId = poolKey.toId();

//         manager.initialize(poolKey, SQRT_PRICE_1_1, ZERO_BYTES);

//         // Mint tokens to test accounts
//         usdc.mint(alice, 100000e6); // $100,000 USDC
//         usdc.mint(bob, 50000e6);    // $50,000 USDC
//         weth.mint(alice, 100e18);   // 100 WETH
//         weth.mint(bob, 50e18);      // 50 WETH

//         // Approve tokens
//         vm.startPrank(alice);
//         usdc.approve(address(manager), type(uint256).max);
//         weth.approve(address(manager), type(uint256).max);
//         usdc.approve(address(vault), type(uint256).max);
//         weth.approve(address(vault), type(uint256).max);
//         vm.stopPrank();

//         vm.startPrank(bob);
//         usdc.approve(address(manager), type(uint256).max);
//         weth.approve(address(manager), type(uint256).max);
//         usdc.approve(address(vault), type(uint256).max);
//         weth.approve(address(vault), type(uint256).max);
//         vm.stopPrank();
//     }

//     function testHookDeployment() public {
//         assertTrue(address(hook) != address(0));
//         assertTrue(address(mevDetector) != address(0));
//         assertTrue(address(vault) != address(0));
//         assertTrue(address(liquidator) != address(0));
//     }

//     function testUserProtectionRegistration() public {
//         vm.startPrank(alice);
        
//         // Register for protection
//         hook.enableProtection{value: 0.005 ether}(2); // STANDARD = 2
        
//         // Check protection status
//         (
//             bool isProtected,
//             uint256 level,
//             uint256 lastLiquidationBlock,
//             uint256 totalMEVSaved,
//             uint256 collateralHealth,
//             uint256 protectionStartTime
//         ) = hook.getUserProtection(alice);
        
//         assertEq(level, 2); // STANDARD = 2
//         assertTrue(isProtected);
//         assertGt(protectionStartTime, 0);
        
//         vm.stopPrank();
//     }

//     function testMEVDetection() public {
//         // Test MEV detection functionality
//         vm.startPrank(alice);
        
//         // Simulate a large swap that might trigger MEV detection
//         bool mevDetected = mevDetector.detectMEV(alice, 10000e6, block.timestamp).riskLevel > 50;
        
//         // MEV detection should work (this is a simplified test)
//         console.log("MEV Detection Result:", mevDetected);
        
//         vm.stopPrank();
//     }

//     function testVaultDeposit() public {
//         vm.startPrank(alice);
        
//         uint256 depositAmount = 1000e6; // $1,000 USDC
        
//         // Deposit USDC to vault
//         vault.deposit(depositAmount);
        
//         // Check user position
//         ICircleUSDCVault.UserPosition memory position = vault.getUserPosition(alice);
//         assertEq(position.depositedAmount, depositAmount);
//         assertEq(position.borrowedAmount, 0);
        
//         vm.stopPrank();
//     }

//     function testCollateralDeposit() public {
//         // First add WETH as collateral asset
//         vault.addCollateralAsset(
//             address(weth),
//             8000, // 80% collateral factor
//             8500, // 85% liquidation threshold
//             500,  // 5% liquidation penalty
//             address(0) // no oracle for test
//         );

//         vm.startPrank(alice);
        
//         uint256 collateralAmount = 1e18; // 1 WETH
        
//         // Deposit WETH as collateral
//         vault.depositCollateral(address(weth), collateralAmount);
        
//         // Check user position
//         ICircleUSDCVault.UserPosition memory position = vault.getUserPosition(alice);
//         assertGt(position.collateralValue, 0);
        
//         vm.stopPrank();
//     }

//     function testBorrowingAgainstCollateral() public {
//         // Setup collateral
//         vault.addCollateralAsset(
//             address(weth),
//             8000, // 80% collateral factor
//             8500, // 85% liquidation threshold
//             500,  // 5% liquidation penalty
//             address(0)
//         );

//         vm.startPrank(alice);
        
//         // Deposit collateral
//         uint256 collateralAmount = 2e18; // 2 WETH
//         vault.depositCollateral(address(weth), collateralAmount);
        
//         // Borrow USDC
//         uint256 borrowAmount = 1000e6; // $1,000 USDC
//         vault.borrow(borrowAmount);
        
//         // Check position
//         ICircleUSDCVault.UserPosition memory position = vault.getUserPosition(alice);
//         assertEq(position.borrowedAmount, borrowAmount);
//         assertGt(position.healthFactor, 110); // Should be healthy
        
//         vm.stopPrank();
//     }

//     function testGradualLiquidation() public {
//         // Setup a position that can be liquidated
//         vault.addCollateralAsset(
//             address(weth),
//             8000,
//             8500,
//             500,
//             address(0)
//         );

//         vm.startPrank(alice);
//         vault.depositCollateral(address(weth), 1e18);
//         vault.borrow(800e6); // Borrow close to limit
//         vm.stopPrank();

//         // Simulate price drop making position liquidatable
//         // (In a real scenario, this would be done through price oracles)
        
//         vm.startPrank(liquidatorBot);
        
//         // Start gradual liquidation
//         bytes32 liquidationId = liquidator.liquidateGradually(
//             alice,
//             400e6, // Liquidate $400
//             5      // Max 5 chunks
//         );
        
//         assertTrue(liquidationId != bytes32(0));
        
//         // Check liquidation status
//         (
//             address borrower,
//             uint256 totalAmount,
//             uint256 executedAmount,
//             uint256 chunksRemaining,
//             uint256 nextExecutionTime
//         ) = liquidator.getLiquidationStatus(liquidationId);
        
//         assertEq(borrower, alice);
//         assertEq(totalAmount, 400e6);
//         assertGt(chunksRemaining, 0);
        
//         vm.stopPrank();
//     }

//     function testSwapWithProtection() public {
//         vm.startPrank(alice);
        
//         // Register for protection
//         hook.registerProtection(ShieldFiHook.ProtectionLevel.PREMIUM);
        
//         // Add liquidity to pool first
//         modifyLiquidityRouter.modifyLiquidity(
//             poolKey,
//             IPoolManager.ModifyLiquidityParams({
//                 tickLower: -60,
//                 tickUpper: 60,
//                 liquidityDelta: 1000e18,
//                 salt: bytes32(0)
//             }),
//             ZERO_BYTES
//         );
        
//         // Perform swap
//         bool zeroForOne = true;
//         int256 amountSpecified = 100e6; // Swap 100 USDC for WETH
        
//         BalanceDelta swapDelta = swapRouter.swap(
//             poolKey,
//             IPoolManager.SwapParams({
//                 zeroForOne: zeroForOne,
//                 amountSpecified: amountSpecified,
//                 sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
//             }),
//             PoolSwapTest.TestSettings({
//                 takeClaims: false,
//                 settleUsingBurn: false
//             }),
//             ZERO_BYTES
//         );
        
//         // Swap should complete successfully
//         assertTrue(swapDelta.amount0() != 0 || swapDelta.amount1() != 0);
        
//         vm.stopPrank();
//     }

//     function testEmergencyControls() public {
//         // Test emergency pause
//         hook.emergencyPause();
//         assertTrue(hook.paused());
        
//         // Test emergency unpause
//         hook.emergencyUnpause();
//         assertFalse(hook.paused());
//     }

//     function testFeeCollection() public {
//         vm.startPrank(alice);
        
//         // Register for premium protection (higher fee)
//         hook.registerProtection(ShieldFiHook.ProtectionLevel.PREMIUM);
        
//         vm.stopPrank();
        
//         // Check fee collection
//         uint256 collectedFees = hook.getCollectedFees();
//         assertGt(collectedFees, 0);
//     }

//     function testHealthFactorCalculation() public {
//         vault.addCollateralAsset(
//             address(weth),
//             8000,
//             8500,
//             500,
//             address(0)
//         );

//         vm.startPrank(alice);
        
//         // Deposit collateral and borrow
//         vault.depositCollateral(address(weth), 2e18);
//         vault.borrow(1000e6);
        
//         // Check health factor
//         uint256 healthFactor = vault.getHealthFactor(alice);
//         assertGt(healthFactor, 110); // Should be healthy (>1.1)
        
//         vm.stopPrank();
//     }

//     function testInterestRateUpdates() public {
//         // Test interest rate updates
//         vault.updateInterestRates();
        
//         ICircleUSDCVault.LendingPool memory pool = vault.getLendingPool();
//         assertGt(pool.lastUpdateTime, 0);
//     }

//     function testOptimalChunking() public {
//         // Test that liquidations are split into 3-8 optimal chunks
//         vault.addCollateralAsset(address(weth), 8000, 8500, 500, address(0));

//         vm.startPrank(alice);
//         vault.depositCollateral(address(weth), 2e18);
//         vault.borrow(1200e6);
//         vm.stopPrank();

//         // Test different liquidation amounts
//         IGradualLiquidator.MarketConditions memory conditions = IGradualLiquidator.MarketConditions({
//             volatility: 300,
//             liquidity: 50000e6,
//             priceImpact: 100,
//             timestamp: block.timestamp
//         });

//         // Small liquidation ($500) should get 3 chunks
//         (uint256 chunks1, , ) = liquidator.calculateOptimalChunking(500e6, 108, conditions);
//         assertEq(chunks1, 3, "Small liquidation should use 3 chunks");

//         // Medium liquidation ($3000) should get 4-6 chunks  
//         (uint256 chunks2, , ) = liquidator.calculateOptimalChunking(3000e6, 108, conditions);
//         assertTrue(chunks2 >= 4 && chunks2 <= 6, "Medium liquidation should use 4-6 chunks");

//         // Large liquidation ($15000) should get 7-8 chunks
//         (uint256 chunks3, , ) = liquidator.calculateOptimalChunking(15000e6, 108, conditions);
//         assertTrue(chunks3 >= 7 && chunks3 <= 8, "Large liquidation should use 7-8 chunks");
//     }

//     function testHealthFactorMonitoring() public {
//         vault.addCollateralAsset(address(weth), 8000, 8500, 500, address(0));

//         vm.startPrank(alice);
//         vault.depositCollateral(address(weth), 1e18);
//         vault.borrow(800e6);
//         vm.stopPrank();

//         // Monitor health factor
//         (uint256 healthFactor, uint256 trend) = liquidator.monitorHealthFactor(alice);
//         assertGt(healthFactor, 0, "Health factor should be calculated");
//         assertEq(trend, 0, "First check should show stable trend");

//         // Check if emergency liquidation should be triggered
//         (bool shouldTrigger, ) = liquidator.shouldTriggerEmergencyLiquidation(alice);
//         assertFalse(shouldTrigger, "Healthy position should not trigger emergency liquidation");
//     }

//     function testLiquidationRewards() public {
//         vault.addCollateralAsset(address(weth), 8000, 8500, 500, address(0));

//         vm.startPrank(alice);
//         vault.depositCollateral(address(weth), 1e18);
//         vault.borrow(800e6);
//         vm.stopPrank();

//         vm.startPrank(liquidatorBot);
        
//         // Start gradual liquidation
//         bytes32 liquidationId = liquidator.liquidateGradually(alice, 400e6, 5);
        
//         // Calculate expected reward
//         uint256 expectedReward = liquidator.calculateChunkReward(liquidationId, 0, 80e6, false);
//         assertGt(expectedReward, 0, "Should calculate reward for chunk");

//         // Check liquidator rewards before execution
//         uint256 rewardsBefore = liquidator.getLiquidatorRewards(liquidatorBot);
        
//         // Skip time to allow chunk execution
//         skipTime(650); // 10 minutes + buffer
        
//         // Execute chunk
//         (bool success, uint256 chunkAmount) = liquidator.executeNextChunk(liquidationId);
        
//         if (success) {
//             // Check rewards increased
//             uint256 rewardsAfter = liquidator.getLiquidatorRewards(liquidatorBot);
//             assertGt(rewardsAfter, rewardsBefore, "Rewards should increase after execution");
//         }
        
//         vm.stopPrank();
//     }

//     function testGasOptimization() public {
//         vault.addCollateralAsset(address(weth), 8000, 8500, 500, address(0));

//         vm.startPrank(alice);
//         vault.depositCollateral(address(weth), 1e18);
//         vault.borrow(800e6);
//         vm.stopPrank();

//         vm.startPrank(liquidatorBot);
        
//         // Start gradual liquidation
//         bytes32 liquidationId = liquidator.liquidateGradually(alice, 400e6, 5);
        
//         // Check gas optimization
//         (bool isOptimal, uint256 estimatedGas) = liquidator.checkGasOptimization(liquidationId);
//         assertTrue(isOptimal, "Gas usage should be within optimal range");
//         assertLe(estimatedGas, 200000, "Estimated gas should be within limit");
        
//         vm.stopPrank();
//     }

//     function testProgressiveChunkSizing() public {
//         vault.addCollateralAsset(address(weth), 8000, 8500, 500, address(0));

//         IGradualLiquidator.MarketConditions memory conditions = IGradualLiquidator.MarketConditions({
//             volatility: 300,
//             liquidity: 50000e6,
//             priceImpact: 100,
//             timestamp: block.timestamp
//         });

//         // Test progressive chunk sizing
//         (uint256 chunks, uint256[] memory chunkSizes, uint256[] memory delays) = 
//             liquidator.calculateOptimalChunking(1000e6, 108, conditions);

//         // First chunk should be smaller than last chunk
//         assertTrue(chunkSizes[0] < chunkSizes[chunks - 1], "Progressive sizing should increase chunk sizes");
        
//         // Delays should increase for later chunks
//         assertTrue(delays[0] <= delays[chunks - 1], "Delays should increase for later chunks");
//     }

//     function testMarketConditionAdjustments() public {
//         // Test high volatility conditions
//         IGradualLiquidator.MarketConditions memory highVolatility = IGradualLiquidator.MarketConditions({
//             volatility: 800, // 8% volatility
//             liquidity: 50000e6,
//             priceImpact: 100,
//             timestamp: block.timestamp
//         });

//         (uint256 chunks1, , ) = liquidator.calculateOptimalChunking(5000e6, 108, highVolatility);

//         // Test low volatility conditions
//         IGradualLiquidator.MarketConditions memory lowVolatility = IGradualLiquidator.MarketConditions({
//             volatility: 200, // 2% volatility
//             liquidity: 50000e6,
//             priceImpact: 100,
//             timestamp: block.timestamp
//         });

//         (uint256 chunks2, , ) = liquidator.calculateOptimalChunking(5000e6, 108, lowVolatility);

//         // High volatility should result in more chunks
//         assertTrue(chunks1 >= chunks2, "High volatility should result in same or more chunks");
//     }

//     function testEmergencyLiquidationTrigger() public {
//         vault.addCollateralAsset(address(weth), 8000, 8500, 500, address(0));

//         vm.startPrank(alice);
//         vault.depositCollateral(address(weth), 1e18);
//         vault.borrow(900e6); // High utilization
//         vm.stopPrank();

//         vm.startPrank(liquidatorBot);
        
//         // Start gradual liquidation
//         bytes32 liquidationId = liquidator.liquidateGradually(alice, 400e6, 5);
        
//         // Simulate health factor dropping critically (would need price oracle manipulation in real scenario)
//         // For test purposes, we'll test the emergency liquidation function directly
//         vm.stopPrank();
        
//         vm.startPrank(address(hook)); // Only ShieldFi hook can trigger emergency liquidation
//         liquidator.emergencyLiquidate(liquidationId, "Critical health factor test");
//         vm.stopPrank();

//         // Check liquidation status
//         (address borrower, , , uint256 chunksRemaining, ) = liquidator.getLiquidationStatus(liquidationId);
//         assertEq(chunksRemaining, 0, "Emergency liquidation should complete all chunks");
//     }

//     // Helper function to simulate time passage
//     function skipTime(uint256 seconds_) internal {
//         vm.warp(block.timestamp + seconds_);
//     }

//     // Helper function to simulate block advancement
//     function skipBlocks(uint256 blocks) internal {
//         vm.roll(block.number + blocks);
//     }
// }

// // Mock ERC20 token for testing
// contract MockERC20 {
//     string public name;
//     string public symbol;
//     uint8 public decimals;
//     uint256 public totalSupply;
    
//     mapping(address => uint256) public balanceOf;
//     mapping(address => mapping(address => uint256)) public allowance;
    
//     event Transfer(address indexed from, address indexed to, uint256 value);
//     event Approval(address indexed owner, address indexed spender, uint256 value);
    
//     constructor(string memory _name, string memory _symbol, uint8 _decimals) {
//         name = _name;
//         symbol = _symbol;
//         decimals = _decimals;
//     }
    
//     function mint(address to, uint256 amount) external {
//         totalSupply += amount;
//         balanceOf[to] += amount;
//         emit Transfer(address(0), to, amount);
//     }
    
//     function transfer(address to, uint256 amount) external returns (bool) {
//         balanceOf[msg.sender] -= amount;
//         balanceOf[to] += amount;
//         emit Transfer(msg.sender, to, amount);
//         return true;
//     }
    
//     function transferFrom(address from, address to, uint256 amount) external returns (bool) {
//         allowance[from][msg.sender] -= amount;
//         balanceOf[from] -= amount;
//         balanceOf[to] += amount;
//         emit Transfer(from, to, amount);
//         return true;
//     }
    
//     function approve(address spender, uint256 amount) external returns (bool) {
//         allowance[msg.sender][spender] = amount;
//         emit Approval(msg.sender, spender, amount);
//         return true;
//     }
// }

// // Hook address mining utility
// library HookMiner {
//     function find(
//         address deployer,
//         uint160 flags,
//         bytes memory creationCode,
//         bytes memory constructorArgs
//     ) internal pure returns (address, bytes32) {
//         bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        
//         for (uint256 i = 0; i < 1000; i++) {
//             bytes32 salt = bytes32(i);
//             address hookAddress = computeAddress(deployer, salt, bytecode);
            
//             if (uint160(hookAddress) & (0x3FF << 150) == flags << 150) {
//                 return (hookAddress, salt);
//             }
//         }
        
//         revert("HookMiner: could not find hook address");
//     }
    
//     function computeAddress(
//         address deployer,
//         bytes32 salt,
//         bytes memory bytecode
//     ) internal pure returns (address) {
//         bytes32 hash = keccak256(
//             abi.encodePacked(
//                 bytes1(0xff),
//                 deployer,
//                 salt,
//                 keccak256(bytecode)
//             )
//         );
        
//         return address(uint160(uint256(hash)));
//     }
// } 