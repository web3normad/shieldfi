// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library HookMiner {
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        
        for (uint256 i = 0; i < 100000; i++) {
            salt = keccak256(abi.encode(deployer, i));
            hookAddress = computeAddress(deployer, salt, bytecode);
            
            if (uint160(hookAddress) & (0xffffff << 144) == flags & (0xffffff << 144)) {
                return (hookAddress, salt);
            }
        }
        
        revert("HookMiner: could not find salt");
    }

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
