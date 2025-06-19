// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/IMEVDetector.sol";
import "./interfaces/IGradualLiquidator.sol";
import "./interfaces/IEigenLayerAVS.sol";
import "./interfaces/ICircleUSDCVault.sol";

/**
 * @title ShieldFiHook
 * @notice MEV-protected lending protocol built on Uniswap v4 hooks
 * @dev Main hook contract that intercepts swaps for MEV detection and protection
 */
contract ShieldFiHook is BaseHook, Ownable, ReentrancyGuard, Pausable {
    using PoolIdLibrary for PoolKey;

    // =============================================================
    //                        ENUMS
    // =============================================================

    enum ProtectionLevel {
        BASIC,      // 0
        STANDARD,   // 1  
        PREMIUM     // 2
    }

    // =============================================================
    //                        STRUCTS
    // =============================================================

    struct ProtectionConfig {
        bool mevProtectionEnabled;        // Pool-level protection toggle
        uint256 liquidationThreshold;    // When to trigger protection (in basis points)
        uint256 protectionFee;           // Fee in basis points (0.1-0.5%)
        uint256 maxGradualChunks;        // Max liquidation chunks (3-8)
        address eigenLayerValidator;     // Assigned validator
        uint256 minHealthFactor;         // Minimum health factor before liquidation
    }

    struct UserProtection {
        bool isProtected;                // User opted into protection
        ProtectionLevel protectionLevel; // Protection level enum
        uint256 lastLiquidationBlock;    // Track liquidation history
        uint256 totalMEVSaved;          // Cumulative protection value
        uint256 collateralHealth;       // Real-time health factor
        uint256 protectionStartTime;    // When protection was enabled
    }

    struct LiquidationEvent {
        address borrower;               // User being liquidated
        uint256 totalAmount;           // Full liquidation amount
        uint256 chunksRemaining;       // Gradual liquidation progress
        uint256 mevCaptured;          // Value extracted and redistributed
        bool isProtected;             // Whether protection was applied
        uint256 timestamp;            // Event timestamp
        PoolId poolId;               // Associated pool
    }

    struct MEVTransaction {
        address sender;
        uint256 amount;
        uint256 timestamp;
        uint256 blockNumber;
        bool flagged;
        uint256 riskLevel;
    }

    // =============================================================
    //                        STATE VARIABLES
    // =============================================================

    // Core integrations
    IMEVDetector public mevDetector;
    IGradualLiquidator public gradualLiquidator;
    IEigenLayerAVS public eigenLayerAVS;
    ICircleUSDCVault public usdcVault;
    IERC20 public immutable usdcToken;

    // Configuration mappings
    mapping(PoolId => ProtectionConfig) public poolConfigs;
    mapping(address => UserProtection) public userProtections;
    mapping(bytes32 => LiquidationEvent) public activeLiquidations;
    mapping(address => MEVTransaction[]) public userTransactionHistory;

    // Fee and reward tracking
    uint256 public totalMEVCaptured;
    uint256 public totalValueRedistributed;
    mapping(address => uint256) public userRewards;
    mapping(address => uint256) public validatorRewards;

    // Protection levels and fees
    mapping(ProtectionLevel => uint256) public protectionLevelFees; // level => fee in wei
    uint256 public constant MAX_PROTECTION_FEE = 50; // 0.5% in basis points
    uint256 public constant MIN_HEALTH_FACTOR = 110; // 1.1 in percentage

    // Emergency controls
    address public emergencyAdmin;
    uint256 public emergencyPauseDelay = 24 hours;

    // =============================================================
    //                        EVENTS
    // =============================================================

    event ProtectionEnabled(address indexed user, uint256 protectionLevel, uint256 fee);
    event ProtectionDisabled(address indexed user);
    event MEVDetected(address indexed user, PoolId indexed poolId, uint256 riskLevel);
    event LiquidationProtected(address indexed borrower, bytes32 indexed liquidationId, uint256 amount);
    event MEVRedistributed(bytes32 indexed liquidationId, uint256 amount, address[] beneficiaries);
    event PoolConfigUpdated(PoolId indexed poolId, ProtectionConfig config);
    event EmergencyLiquidation(address indexed borrower, uint256 amount, string reason);

    // =============================================================
    //                        ERRORS
    // =============================================================

    error InvalidProtectionLevel();
    error InsufficientFee();
    error ProtectionNotEnabled();
    error InvalidHealthFactor();
    error MEVDetectionFailed();
    error LiquidationInProgress();
    error UnauthorizedValidator();
    error InvalidPoolConfig();

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(
        IPoolManager _poolManager,
        address _usdcToken,
        address _emergencyAdmin
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        usdcToken = IERC20(_usdcToken);
        emergencyAdmin = _emergencyAdmin;
        
        // Set default protection level fees
        protectionLevelFees[ProtectionLevel.BASIC] = 0.001 ether; // Basic: 0.001 ETH
        protectionLevelFees[ProtectionLevel.STANDARD] = 0.005 ether; // Standard: 0.005 ETH
        protectionLevelFees[ProtectionLevel.PREMIUM] = 0.01 ether;  // Premium: 0.01 ETH
    }

    // =============================================================
    //                        HOOK PERMISSIONS
    // =============================================================

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,   // Pool configuration
            afterInitialize: false,
            beforeAddLiquidity: true, // Position tracking
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // Liquidation detection
            afterRemoveLiquidity: false,
            beforeSwap: true,         // MEV detection
            afterSwap: true,          // MEV redistribution
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =============================================================
    //                        HOOK IMPLEMENTATIONS
    // =============================================================

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        internal
        returns (bytes4)
    {
        // Set default protection configuration for new pools
        PoolId poolId = key.toId();
        poolConfigs[poolId] = ProtectionConfig({
            mevProtectionEnabled: true,
            liquidationThreshold: 500, // 5% in basis points
            protectionFee: 25,         // 0.25% in basis points
            maxGradualChunks: 5,
            eigenLayerValidator: address(0), // To be set later
            minHealthFactor: MIN_HEALTH_FACTOR
        });

        emit PoolConfigUpdated(poolId, poolConfigs[poolId]);
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (paused()) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId poolId = key.toId();
        ProtectionConfig memory config = poolConfigs[poolId];

        if (!config.mevProtectionEnabled) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // MEV Detection
        if (address(mevDetector) != address(0)) {
            try mevDetector.detectMEV(sender, key, params) returns (bool isMEVAttempt, uint256 riskLevel) {
                if (isMEVAttempt) {
                    // Record MEV transaction
                    userTransactionHistory[sender].push(MEVTransaction({
                        sender: sender,
                        amount: params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified),
                        timestamp: block.timestamp,
                        blockNumber: block.number,
                        flagged: true,
                        riskLevel: riskLevel
                    }));

                    emit MEVDetected(sender, poolId, riskLevel);

                    // High-risk transactions get additional scrutiny
                    if (riskLevel > 80 && address(eigenLayerAVS) != address(0)) {
                        // Submit to EigenLayer for validation
                        bytes32 txHash = keccak256(abi.encode(sender, key, params, block.timestamp));
                        eigenLayerAVS.submitToValidator(txHash, abi.encode(sender, riskLevel));
                    }
                }
            } catch {
                // MEV detection failed, continue with transaction but log
                revert MEVDetectionFailed();
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (paused()) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Check if this was a protected transaction and redistribute MEV
        UserProtection memory protection = userProtections[sender];
        if (protection.isProtected) {
            _redistributeMEVValue(sender, key, delta);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // Track liquidity positions for health factor calculations
        if (address(usdcVault) != address(0)) {
            usdcVault.updatePositionTracking(sender, key, params);
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        if (paused()) {
            return BaseHook.beforeRemoveLiquidity.selector;
        }

        // Check if this is a liquidation event
        if (address(usdcVault) != address(0)) {
            uint256 healthFactor = usdcVault.getHealthFactor(sender);
            ProtectionConfig memory config = poolConfigs[key.toId()];

            if (healthFactor < config.minHealthFactor) {
                // This is a liquidation - check if protection should apply
                UserProtection memory protection = userProtections[sender];
                if (protection.isProtected) {
                    _triggerProtectedLiquidation(sender, key, params, healthFactor);
                }
            }
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // =============================================================
    //                        USER PROTECTION MANAGEMENT
    // =============================================================

    function enableProtection(ProtectionLevel protectionLevel) external payable nonReentrant {
        uint256 requiredFee = protectionLevelFees[protectionLevel];
        if (msg.value < requiredFee) {
            revert InsufficientFee();
        }

        userProtections[msg.sender] = UserProtection({
            isProtected: true,
            protectionLevel: protectionLevel,
            lastLiquidationBlock: 0,
            totalMEVSaved: 0,
            collateralHealth: 100, // Default 100%
            protectionStartTime: block.timestamp
        });

        // Refund excess payment
        if (msg.value > requiredFee) {
            payable(msg.sender).transfer(msg.value - requiredFee);
        }

        emit ProtectionEnabled(msg.sender, uint256(protectionLevel), requiredFee);
    }

    function registerProtection(ProtectionLevel protectionLevel) external payable nonReentrant {
        uint256 requiredFee = protectionLevelFees[protectionLevel];
        if (msg.value < requiredFee) {
            revert InsufficientFee();
        }

        userProtections[msg.sender] = UserProtection({
            isProtected: true,
            protectionLevel: protectionLevel,
            lastLiquidationBlock: 0,
            totalMEVSaved: 0,
            collateralHealth: 100, // Default 100%
            protectionStartTime: block.timestamp
        });

        // Refund excess payment
        if (msg.value > requiredFee) {
            payable(msg.sender).transfer(msg.value - requiredFee);
        }

        emit ProtectionEnabled(msg.sender, uint256(protectionLevel), requiredFee);
    }

    function disableProtection() external {
        if (!userProtections[msg.sender].isProtected) {
            revert ProtectionNotEnabled();
        }

        delete userProtections[msg.sender];
        emit ProtectionDisabled(msg.sender);
    }

    function upgradeProtection(ProtectionLevel newLevel) external payable {
        UserProtection storage protection = userProtections[msg.sender];
        if (!protection.isProtected) {
            revert ProtectionNotEnabled();
        }

        if (uint256(newLevel) <= uint256(protection.protectionLevel)) {
            revert InvalidProtectionLevel();
        }

        uint256 upgradeFee = protectionLevelFees[newLevel] - protectionLevelFees[protection.protectionLevel];
        if (msg.value < upgradeFee) {
            revert InsufficientFee();
        }

        protection.protectionLevel = newLevel;

        if (msg.value > upgradeFee) {
            payable(msg.sender).transfer(msg.value - upgradeFee);
        }

        emit ProtectionEnabled(msg.sender, uint256(newLevel), upgradeFee);
    }

    // Additional admin function to update protection fees using enum
    function updateProtectionFees(ProtectionLevel level, uint256 fee) external onlyOwner {
        protectionLevelFees[level] = fee;
    }

    // View function to get protection fee using enum
    function getProtectionFee(ProtectionLevel level) external view returns (uint256) {
        return protectionLevelFees[level];
    }

    // =============================================================
    //                        LIQUIDATION MANAGEMENT
    // =============================================================

    function _triggerProtectedLiquidation(
        address borrower,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        uint256 healthFactor
    ) internal {
        if (address(gradualLiquidator) == address(0)) {
            // Fallback to emergency liquidation
            _emergencyLiquidation(borrower, uint256(-params.liquidityDelta), "No gradual liquidator");
            return;
        }

        ProtectionConfig memory config = poolConfigs[key.toId()];
        uint256 liquidationAmount = uint256(-params.liquidityDelta);

        // Create liquidation event
        bytes32 liquidationId = keccak256(abi.encode(borrower, liquidationAmount, block.timestamp));
        
        activeLiquidations[liquidationId] = LiquidationEvent({
            borrower: borrower,
            totalAmount: liquidationAmount,
            chunksRemaining: config.maxGradualChunks,
            mevCaptured: 0,
            isProtected: true,
            timestamp: block.timestamp,
            poolId: key.toId()
        });

        // Trigger gradual liquidation
        gradualLiquidator.liquidateGradually(borrower, liquidationAmount, config.maxGradualChunks);

        emit LiquidationProtected(borrower, liquidationId, liquidationAmount);
    }

    function _emergencyLiquidation(address borrower, uint256 amount, string memory reason) internal {
        // Emergency liquidation bypasses gradual system
        if (address(usdcVault) != address(0)) {
            usdcVault.emergencyLiquidate(borrower, amount);
        }
        emit EmergencyLiquidation(borrower, amount, reason);
    }

    // =============================================================
    //                        MEV REDISTRIBUTION
    // =============================================================

    function _redistributeMEVValue(
        address user,
        PoolKey calldata key,
        BalanceDelta delta
    ) internal {
        // Calculate MEV value captured
        uint256 mevValue = _calculateMEVValue(delta);
        if (mevValue == 0) return;

        totalMEVCaptured += mevValue;

        // Distribution: 75% to user, 15% to LPs, 10% to protocol
        uint256 userShare = (mevValue * 75) / 100;
        uint256 lpShare = (mevValue * 15) / 100;
        uint256 protocolShare = mevValue - userShare - lpShare;

        // Update user rewards
        userRewards[user] += userShare;
        userProtections[user].totalMEVSaved += userShare;

        // Track total redistributed
        totalValueRedistributed += userShare;

        // TODO: Implement LP reward distribution
        // TODO: Handle protocol treasury
    }

    function _calculateMEVValue(BalanceDelta delta) internal pure returns (uint256) {
        // Simplified MEV calculation - in production this would be more sophisticated
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        
        uint256 totalValue = 0;
        if (amount0 > 0) totalValue += uint256(uint128(amount0));
        if (amount1 > 0) totalValue += uint256(uint128(amount1));
        
        // Assume 0.1% of transaction value as MEV (simplified)
        return (totalValue * 10) / 10000;
    }

    // =============================================================
    //                        ADMIN FUNCTIONS
    // =============================================================

    function setMEVDetector(address _mevDetector) external onlyOwner {
        mevDetector = IMEVDetector(_mevDetector);
    }

    function setGradualLiquidator(address _gradualLiquidator) external onlyOwner {
        gradualLiquidator = IGradualLiquidator(_gradualLiquidator);
    }

    function setEigenLayerAVS(address _eigenLayerAVS) external onlyOwner {
        eigenLayerAVS = IEigenLayerAVS(_eigenLayerAVS);
    }

    function setUSDCVault(address _usdcVault) external onlyOwner {
        usdcVault = ICircleUSDCVault(_usdcVault);
    }

    function updatePoolConfig(PoolId poolId, ProtectionConfig calldata config) external onlyOwner {
        if (config.protectionFee > MAX_PROTECTION_FEE) {
            revert InvalidPoolConfig();
        }
        poolConfigs[poolId] = config;
        emit PoolConfigUpdated(poolId, config);
    }

    function updateProtectionFees(uint256 level, uint256 fee) external onlyOwner {
        if (level < 1 || level > 3) {
            revert InvalidProtectionLevel();
        }
        protectionLevelFees[ProtectionLevel(level)] = fee;
    }

    function emergencyPause() external {
        require(msg.sender == emergencyAdmin || msg.sender == owner(), "Unauthorized");
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    function getUserProtection(address user) external view returns (UserProtection memory) {
        return userProtections[user];
    }

    function getPoolConfig(PoolId poolId) external view returns (ProtectionConfig memory) {
        return poolConfigs[poolId];
    }

    function getLiquidationEvent(bytes32 liquidationId) external view returns (LiquidationEvent memory) {
        return activeLiquidations[liquidationId];
    }

    function getUserTransactionHistory(address user) external view returns (MEVTransaction[] memory) {
        return userTransactionHistory[user];
    }

    function getProtectionFee(uint256 level) external view returns (uint256) {
        return protectionLevelFees[ProtectionLevel(level)];
    }

    // =============================================================
    //                        RECEIVE FUNCTION
    // =============================================================

    receive() external payable {
        // Accept ETH for protection fees
    }
} 