// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ShieldFiAVS} from "../src/ShieldFiAVS.sol";
import {ShieldFiHook} from "../src/ShieldFiHook.sol";
import {GradualLiquidationManager} from "../src/GradualLiquidationManager.sol";

/**
 * @title DeployAVS
 * @notice Deployment script for ShieldFi AVS integration with EigenLayer
 * @dev Deploys and configures the complete ShieldFi ecosystem with AVS
 */
contract DeployAVS is Script {
    // Deployment addresses will be set based on network
    address public deployer;
    
    // Contract instances
    ShieldFiAVS public avs;
    ShieldFiHook public hook;
    GradualLiquidationManager public liquidationManager;
    
    // Configuration constants
    uint256 public constant MIN_VALIDATOR_STAKE = 32 ether;
    uint256 public constant MAX_VALIDATORS = 100;
    string public constant OPERATOR_SET_NAME = "ShieldFi MEV Protection";
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== ShieldFi AVS Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Network:", block.chainid);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy ShieldFi AVS
        deployAVS();
        
        // Step 2: Deploy and integrate ShieldFi Hook (if not already deployed)
        deployHookIntegration();
        
        // Step 3: Configure AVS operator sets and slashing conditions
        configureAVS();
        
        // Step 4: Set up integration between components
        setupIntegration();
        
        // Step 5: Verify deployment
        verifyDeployment();
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Complete ===");
        logDeploymentAddresses();
    }
    
    function deployAVS() internal {
        console.log("\n1. Deploying ShieldFi AVS...");
        
        avs = new ShieldFiAVS(deployer);
        
        console.log("ShieldFi AVS deployed at:", address(avs));
        console.log("Owner:", deployer);
        console.log("Fair sequencing enabled:", avs.fairSequencingEnabled());
    }
    
    function deployHookIntegration() internal {
        console.log("\n2. Setting up Hook Integration...");
        
        // Check if hook is already deployed (you might want to use existing deployment)
        address existingHook = vm.envOr("EXISTING_HOOK_ADDRESS", address(0));
        
        if (existingHook != address(0)) {
            console.log("Using existing ShieldFi Hook at:", existingHook);
            hook = ShieldFiHook(payable(existingHook));
        } else {
            console.log("Hook address not provided - AVS can be connected later");
            console.log("Use setShieldFiHook() to connect after hook deployment");
        }
    }
    
    function configureAVS() internal {
        console.log("\n3. Configuring AVS...");
        
        // Create default operator set
        bytes32 slashingConditions = keccak256(abi.encodePacked(
            "MEV_DETECTION_FAILURE",
            "INVALID_SEQUENCING",
            "MALICIOUS_VALIDATION"
        ));
        
        uint256 operatorSetId = avs.createOperatorSet(
            OPERATOR_SET_NAME,
            MIN_VALIDATOR_STAKE,
            MAX_VALIDATORS,
            slashingConditions
        );
        
        console.log("Created operator set:", operatorSetId);
        console.log("Min stake:", MIN_VALIDATOR_STAKE);
        console.log("Max validators:", MAX_VALIDATORS);
        
        // Add slashing conditions
        addSlashingConditions();
    }
    
    function addSlashingConditions() internal {
        console.log("\n4. Adding Slashing Conditions...");
        
        // MEV detection failure
        bytes32 mevCondition = avs.addSlashingCondition(
            "Failed to detect MEV when required",
            5 ether // 5 ETH slash for MEV detection failure
        );
        console.log("MEV detection failure condition:", vm.toString(mevCondition));
        
        // Invalid sequencing
        bytes32 sequencingCondition = avs.addSlashingCondition(
            "Provided invalid transaction sequencing",
            3 ether // 3 ETH slash for invalid sequencing
        );
        console.log("Invalid sequencing condition:", vm.toString(sequencingCondition));
        
        // Malicious validation
        bytes32 validationCondition = avs.addSlashingCondition(
            "Provided malicious transaction validation",
            10 ether // 10 ETH slash for malicious validation
        );
        console.log("Malicious validation condition:", vm.toString(validationCondition));
        
        // Performance degradation
        bytes32 performanceCondition = avs.addSlashingCondition(
            "Consistent performance degradation",
            1 ether // 1 ETH slash for performance issues
        );
        console.log("Performance degradation condition:", vm.toString(performanceCondition));
    }
    
    function setupIntegration() internal {
        console.log("\n5. Setting up Component Integration...");
        
        if (address(hook) != address(0)) {
            // Connect AVS to Hook
            avs.setShieldFiHook(hook);
            console.log("Connected AVS to ShieldFi Hook");
            
            // If hook has AVS integration function, call it
            // hook.setAVS(address(avs)); // Uncomment if this function exists
        }
        
        console.log("Integration setup complete");
    }
    
    function verifyDeployment() internal view {
        console.log("\n6. Verifying Deployment...");
        
        // Verify AVS deployment
        require(address(avs) != address(0), "AVS deployment failed");
        require(avs.owner() == deployer, "AVS owner not set correctly");
        require(avs.operatorSetCount() > 0, "No operator sets created");
        require(avs.slashingConditionCount() > 0, "No slashing conditions added");
        
        console.log("[+] AVS deployed and configured correctly");
        console.log("[+] Operator sets created:", avs.operatorSetCount());
        console.log("[+] Slashing conditions added:", avs.slashingConditionCount());
        console.log("[+] Active validators:", avs.getActiveValidatorCount());
        
        if (address(hook) != address(0)) {
            console.log("[+] Hook integration configured");
        }
    }
    
    function logDeploymentAddresses() internal view {
        console.log("\n=== Deployment Addresses ===");
        console.log("ShieldFi AVS:", address(avs));
        
        if (address(hook) != address(0)) {
            console.log("ShieldFi Hook:", address(hook));
        }
        
        console.log("Deployer/Owner:", deployer);
        console.log("Network Chain ID:", block.chainid);
        
        console.log("\n=== Next Steps ===");
        console.log("1. Validators can register using registerValidator()");
        console.log("2. Minimum stake required:", MIN_VALIDATOR_STAKE);
        console.log("3. Connect to ShieldFi Hook if not already done");
        console.log("4. Configure hook to use AVS for validation");
        console.log("5. Test with EigenLayer testnet");
        
        console.log("\n=== Environment Variables for Frontend ===");
        console.log("SHIELDFI_AVS_ADDRESS=", address(avs));
        if (address(hook) != address(0)) {
            console.log("SHIELDFI_HOOK_ADDRESS=", address(hook));
        }
        console.log("DEPLOYER_ADDRESS=", deployer);
    }
}

/**
 * @title AVSDemo
 * @notice Demo script showing AVS functionality
 */
contract AVSDemo is Script {
    ShieldFiAVS public avs;
    
    // Demo addresses
    address public constant DEMO_VALIDATOR1 = 0x1234567890123456789012345678901234567890;
    address public constant DEMO_VALIDATOR2 = 0x0987654321098765432109876543210987654321;
    address public constant DEMO_USER = 0x1111111111111111111111111111111111111111;
    
    function run() external {
        address avsAddress = vm.envAddress("SHIELDFI_AVS_ADDRESS");
        avs = ShieldFiAVS(payable(avsAddress));
        
        console.log("=== ShieldFi AVS Demo ===");
        console.log("AVS Address:", address(avs));
        
        // Demo validator registration
        demoValidatorRegistration();
        
        // Demo transaction validation
        demoTransactionValidation();
        
        // Demo fair sequencing
        demoFairSequencing();
        
        // Demo slashing (simulation)
        demoSlashing();
        
        console.log("=== Demo Complete ===");
    }
    
    function demoValidatorRegistration() internal view {
        console.log("\n1. VALIDATOR REGISTRATION DEMO");
        console.log("------------------------------");
        
        console.log("Current active validators:", avs.getActiveValidatorCount());
        console.log("Operator sets available:", avs.operatorSetCount());
        console.log("Minimum stake required:", avs.MIN_VALIDATOR_STAKE());
        
        console.log("\nTo register as a validator:");
        console.log("1. Ensure you have at least", avs.MIN_VALIDATOR_STAKE(), "wei");
        console.log("2. Call registerValidator(operatorSetId, stake, metadataURI)");
        console.log("3. Send ETH equal to your stake amount");
    }
    
    function demoTransactionValidation() internal view {
        console.log("\n2. TRANSACTION VALIDATION DEMO");
        console.log("-------------------------------");
        
        console.log("Validation timeout:", avs.VALIDATION_TIMEOUT(), "seconds");
        console.log("Current validation requests:", avs.validationRequestCount());
        
        console.log("\nTo request transaction validation:");
        console.log("1. Call requestValidation(transactionHash, requiredValidators)");
        console.log("2. Validators submit responses with submitValidation()");
        console.log("3. Validation completes when enough validators respond");
    }
    
    function demoFairSequencing() internal view {
        console.log("\n3. FAIR SEQUENCING DEMO");
        console.log("-----------------------");
        
        console.log("Fair sequencing enabled:", avs.fairSequencingEnabled());
        console.log("Current sequence number:", avs.currentSequenceNumber());
        console.log("Sequencing window:", avs.SEQUENCING_WINDOW(), "seconds");
        
        console.log("\nTo create sequencing batch:");
        console.log("1. Call createSequencingBatch(transactions[])");
        console.log("2. Selected sequencer finalizes with finalizeSequencingBatch()");
        console.log("3. Sequencer receives rewards for successful finalization");
    }
    
    function demoSlashing() internal view {
        console.log("\n4. SLASHING CONDITIONS DEMO");
        console.log("---------------------------");
        
        console.log("Total slashing conditions:", avs.slashingConditionCount());
        console.log("Slashing percentage:", avs.SLASHING_PERCENTAGE(), "basis points");
        console.log("Total amount slashed:", avs.totalAmountSlashed());
        
        console.log("\nSlashing triggers:");
        console.log("- MEV detection failure");
        console.log("- Invalid transaction sequencing");
        console.log("- Malicious validation responses");
        console.log("- Consistent performance degradation");
        
        console.log("\nSlashing amounts vary by condition severity");
    }
} 