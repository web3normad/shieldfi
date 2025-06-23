// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner - a library for mining hook addresses
/// @dev This library is used to find valid hook addresses for Uniswap V4 testing
library HookMiner {
    // mask to slice out the bottom 14 bits of the address
    uint160 constant FLAG_MASK = 0x3FFF;

    // Maximum number of iterations to prevent infinite loops
    uint256 constant MAX_LOOP = 100_000;

    /// @dev Find a salt that will produce a hook address with the desired flags
    /// @param deployer The address that will deploy the hook
    /// @param flags The desired flags for the hook
    /// @param creationCode The creation code of the hook contract
    /// @param constructorArgs The constructor arguments for the hook contract
    /// @return hookAddress The address of the hook
    /// @return salt The salt used to deploy the hook
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        // Combine creation code with constructor arguments
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            salt = keccak256(abi.encodePacked(i));
            hookAddress = computeAddress(deployer, salt, bytecode);
            
            if (uint160(hookAddress) & FLAG_MASK == flags) {
                return (hookAddress, salt);
            }
        }
        
        revert("HookMiner: could not find salt");
    }

    /// @dev Compute the address of a contract deployed with CREATE2
    /// @param deployer The address that will deploy the contract
    /// @param salt The salt used for CREATE2
    /// @param bytecode The bytecode of the contract
    /// @return The computed address
    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes memory bytecode
    ) internal pure returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                deployer,
                salt,
                keccak256(bytecode)
            )
        );
        
        return address(uint160(uint256(hash)));
    }
} 