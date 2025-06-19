// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.24;

// import "forge-std/Script.sol";
// import "forge-std/console.sol";

// import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
// import {Hooks} from "v4-core/src/libraries/Hooks.sol";
// import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey} from "v4-core/src/types/PoolKey.sol";
// import {Currency} from "v4-core/src/types/Currency.sol";

// import "../src/ShieldFiHook.sol";
// import "../src/MEVDetector.sol";
// import "../src/CircleUSDCVault.sol";
// import "../src/GradualLiquidator.sol";

// contract DeployScript is Script {
//     // Deployment addresses (update these for your target network)
//     address constant POOL_MANAGER = 0x0000000000000000000000000000000000000000; // Update with actual address
//     address constant USDC_ADDRESS = 0xA0b86A33E6441b8435b662F0e2d0B8A0E4b5B5B5; // Update with actual USDC address
    
//     // Deployment configuration
//     struct DeploymentConfig {
//         address poolManager;
//         address usdcToken;
//         address emergencyAdmin;
//         uint256 standardProtectionFee;
//         uint256 premiumProtectionFee;
//     }

//     function run() external {
//         uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
//         address deployer = vm.addr(deployerPrivateKey);
        
//         console.log("Deploying ShieldFi contracts...");
//         console.log("Deployer:", deployer);
//         console.log("Deployer balance:", deployer.balance);

//         vm.startBroadcast(deployerPrivateKey);

//         // Deploy configuration
//         DeploymentConfig memory config = DeploymentConfig({
//             poolManager: POOL_MANAGER,
//             usdcToken: USDC_ADDRESS,
//             emergencyAdmin: deployer,
//             standardProtectionFee: 0.001 ether, // 0.001 ETH
//             premiumProtectionFee: 0.005 ether   // 0.005 ETH
//         });

//         // 1. Deploy MEV Detector
//         console.log("Deploying MEV Detector...");
//         MEVDetector mevDetector = new MEVDetector();
//         console.log("MEV Detector deployed at:", address(mevDetector));

//         // 2. Deploy Circle USDC Vault
//         console.log("Deploying Circle USDC Vault...");
//         CircleUSDCVault vault = new CircleUSDCVault(config.usdcToken);
//         console.log("Circle USDC Vault deployed at:", address(vault));

//         // 3. Deploy Gradual Liquidator
//         console.log("Deploying Gradual Liquidator...");
//         GradualLiquidator liquidator = new GradualLiquidator(
//             address(vault),
//             address(mevDetector),
//             config.usdcToken
//         );
//         console.log("Gradual Liquidator deployed at:", address(liquidator));

//         // 4. Deploy ShieldFi Hook with proper address mining
//         console.log("Mining hook address...");
//         uint160 flags = uint160(
//             Hooks.BEFORE_SWAP_FLAG | 
//             Hooks.AFTER_SWAP_FLAG | 
//             Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
//             Hooks.AFTER_ADD_LIQUIDITY_FLAG |
//             Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
//             Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
//         );

//         (address hookAddress, bytes32 salt) = HookMiner.find(
//             deployer,
//             flags,
//             type(ShieldFiHook).creationCode,
//             abi.encode(
//                 config.poolManager,
//                 config.usdcToken,
//                 config.emergencyAdmin
//             )
//         );

//         console.log("Hook will be deployed at:", hookAddress);
//         console.log("Using salt:", vm.toString(salt));

//         ShieldFiHook hook = new ShieldFiHook{salt: salt}(
//             IPoolManager(config.poolManager),
//             config.usdcToken,
//             config.emergencyAdmin
//         );
        
//         require(address(hook) == hookAddress, "Hook address mismatch");
//         console.log("ShieldFi Hook deployed at:", address(hook));

//         // 5. Configure integrations
//         console.log("Configuring integrations...");
        
//         // Set up hook integrations
//         hook.setMEVDetector(address(mevDetector));
//         hook.setGradualLiquidator(address(liquidator));
//         hook.setUSDCVault(address(vault));
        
//         // Set protection fees
//         hook.updateProtectionFees(
//             uint256(ShieldFiHook.ProtectionLevel.STANDARD),
//             config.standardProtectionFee
//         );
//         hook.updateProtectionFees(
//             uint256(ShieldFiHook.ProtectionLevel.PREMIUM),
//             config.premiumProtectionFee
//         );

//         // Configure vault
//         vault.setShieldFiHook(address(hook));
        
//         // Configure liquidator
//         liquidator.setShieldFiHook(address(hook));
        
//         // Set up MEV detection thresholds
//         mevDetector.updateDetectionThreshold("sandwich_threshold", 50); // 5% price impact
//         mevDetector.updateDetectionThreshold("hft_threshold", 10);      // 10 transactions per block
//         mevDetector.updateDetectionThreshold("large_tx_threshold", 100000e6); // $100k USDC
//         mevDetector.updateDetectionThreshold("timing_threshold", 2);    // 2 blocks

//         // Add initial collateral assets to vault (example with WETH)
//         // Note: Update these addresses for your target network
//         address wethAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // Mainnet WETH
//         if (block.chainid != 1) {
//             // For testnets, you might need to deploy mock tokens or use different addresses
//             console.log("Warning: Using mainnet WETH address on non-mainnet network");
//         }
        
//         vault.addCollateralAsset(
//             wethAddress,
//             8000, // 80% collateral factor
//             8500, // 85% liquidation threshold
//             500,  // 5% liquidation penalty
//             address(0) // Oracle address - update with actual price oracle
//         );

//         console.log("Configuration complete!");

//         vm.stopBroadcast();

//         // Log deployment summary
//         console.log("\n=== DEPLOYMENT SUMMARY ===");
//         console.log("Network:", getNetworkName());
//         console.log("Deployer:", deployer);
//         console.log("MEV Detector:", address(mevDetector));
//         console.log("Circle USDC Vault:", address(vault));
//         console.log("Gradual Liquidator:", address(liquidator));
//         console.log("ShieldFi Hook:", address(hook));
//         console.log("Hook Salt:", vm.toString(salt));
//         console.log("Standard Protection Fee:", config.standardProtectionFee);
//         console.log("Premium Protection Fee:", config.premiumProtectionFee);
//         console.log("========================\n");

//         // Save deployment addresses to file
//         saveDeploymentAddresses(
//             address(mevDetector),
//             address(vault),
//             address(liquidator),
//             address(hook)
//         );
//     }

//     function getNetworkName() internal view returns (string memory) {
//         if (block.chainid == 1) return "Ethereum Mainnet";
//         if (block.chainid == 11155111) return "Sepolia";
//         if (block.chainid == 5) return "Goerli";
//         if (block.chainid == 137) return "Polygon";
//         if (block.chainid == 80001) return "Mumbai";
//         if (block.chainid == 42161) return "Arbitrum One";
//         if (block.chainid == 421613) return "Arbitrum Goerli";
//         if (block.chainid == 10) return "Optimism";
//         if (block.chainid == 420) return "Optimism Goerli";
//         return "Unknown Network";
//     }

//     function saveDeploymentAddresses(
//         address mevDetector,
//         address vault,
//         address liquidator,
//         address hook
//     ) internal {
//         string memory json = string(abi.encodePacked(
//             '{\n',
//             '  "network": "', getNetworkName(), '",\n',
//             '  "chainId": ', vm.toString(block.chainid), ',\n',
//             '  "timestamp": ', vm.toString(block.timestamp), ',\n',
//             '  "contracts": {\n',
//             '    "MEVDetector": "', vm.toString(mevDetector), '",\n',
//             '    "CircleUSDCVault": "', vm.toString(vault), '",\n',
//             '    "GradualLiquidator": "', vm.toString(liquidator), '",\n',
//             '    "ShieldFiHook": "', vm.toString(hook), '"\n',
//             '  }\n',
//             '}'
//         ));

//         string memory filename = string(abi.encodePacked(
//             "deployments/",
//             vm.toString(block.chainid),
//             "-deployment.json"
//         ));

//         vm.writeFile(filename, json);
//         console.log("Deployment addresses saved to:", filename);
//     }
// }

// // Hook address mining utility (same as in test file)
// library HookMiner {
//     function find(
//         address deployer,
//         uint160 flags,
//         bytes memory creationCode,
//         bytes memory constructorArgs
//     ) internal pure returns (address, bytes32) {
//         bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        
//         for (uint256 i = 0; i < 10000; i++) {
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