// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "lib/v4-core/src/PoolManager.sol";
import {ShieldFiHook} from "../src/ShieldFiHook.sol";
import {GradualLiquidationManager} from "../src/GradualLiquidationManager.sol";
import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying ShieldFi system with account:", deployer);
        console.log("Account balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy PoolManager if not provided
        address poolManagerAddress = vm.envOr("POOL_MANAGER_ADDRESS", address(0));
        if (poolManagerAddress == address(0)) {
            PoolManager poolManager = new PoolManager(deployer);
            poolManagerAddress = address(poolManager);
            console.log("Deployed PoolManager at:", poolManagerAddress);
        } else {
            console.log("Using existing PoolManager at:", poolManagerAddress);
        }

        // Get configuration addresses
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address rewardToken = vm.envOr("REWARD_TOKEN_ADDRESS", address(0));
        
        // Deploy reward token if not provided (for demo purposes)
        if (rewardToken == address(0)) {
            // In a real deployment, this would be an actual token deployment
            rewardToken = address(0x123456789); // Mock address for demo
            console.log("Using mock reward token at:", rewardToken);
        }

        console.log("Hook owner will be:", owner);

        // Calculate required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // Mine hook address with correct flags
        (address hookAddress, bytes32 salt) = mineSalt(deployer, flags);
        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        // Deploy the hook
        ShieldFiHook hook = new ShieldFiHook{salt: salt}(
            IPoolManager(poolManagerAddress),
            owner
        );

        console.log("ShieldFiHook deployed at:", address(hook));
        
        // Deploy GradualLiquidationManager
        GradualLiquidationManager liquidationManager = new GradualLiquidationManager(
            IPoolManager(poolManagerAddress),
            owner,
            rewardToken
        );
        
        console.log("GradualLiquidationManager deployed at:", address(liquidationManager));
        
        // Integrate the components
        hook.setLiquidationManager(liquidationManager);
        console.log("Integrated liquidation manager with hook");
        
        // Display system configuration
        console.log("\n=== System Configuration ===");
        console.log("Hook permissions configured:");
        
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        console.log("- beforeSwap:", permissions.beforeSwap);
        console.log("- afterSwap:", permissions.afterSwap);
        
        console.log("Global protection fee:", hook.globalProtectionFee());
        console.log("Fee recipient:", hook.feeRecipient());
        console.log("Liquidation manager:", address(hook.liquidationManager()));
        
        console.log("\n=== Integration Status ===");
        console.log("+ ShieldFi Hook deployed and configured");
        console.log("+ Gradual Liquidation Manager deployed");
        console.log("+ Components integrated successfully");
        console.log("+ System ready for operation");

        vm.stopBroadcast();
    }

    function mineSalt(address deployer, uint160 flags) internal pure returns (address, bytes32) {
        bytes memory creationCode = abi.encodePacked(
            type(ShieldFiHook).creationCode
        );
        
        for (uint256 i = 0; i < 1000000; i++) {
            bytes32 salt = bytes32(i);
            address hookAddress = computeAddress(deployer, salt, creationCode);
            
            if (uint160(hookAddress) & flags == flags) {
                return (hookAddress, salt);
            }
        }
        
        revert("DeployScript: Could not find valid hook address");
    }
    
    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes memory creationCode
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            keccak256(creationCode)
        )))));
    }
} 