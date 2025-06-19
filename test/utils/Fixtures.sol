// ============ test/utils/Fixtures.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";

// Simple test token - no external dependencies
contract TestToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }
    
    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "Insufficient balance");
        totalSupply -= amount;
        balanceOf[from] -= amount;
        emit Transfer(from, address(0), amount);
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        
        emit Transfer(from, to, amount);
        return true;
    }
}

contract Fixtures is Test {
    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolDonateTest donateRouter;

    TestToken currency0;
    TestToken currency1;

    function deployFreshManagerAndRouters() internal {
        // PoolManager constructor requires a controllerAddress parameter
        // For testing, we can use address(this) as the controller
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);
    }

    function deployMintAndApprove2Currencies() internal returns (TestToken, TestToken) {
        TestToken _currency0 = new TestToken("Token0", "TK0");
        TestToken _currency1 = new TestToken("Token1", "TK1");

        // Sort tokens to ensure currency0 < currency1
        if (address(_currency0) > address(_currency1)) {
            (currency0, currency1) = (_currency1, _currency0);
        } else {
            (currency0, currency1) = (_currency0, _currency1);
        }

        // Mint initial supply to test contract
        currency0.mint(address(this), 1000000 ether);
        currency1.mint(address(this), 1000000 ether);

        // Approve all routers and manager
        address[4] memory toApprove = [
            address(swapRouter),
            address(modifyLiquidityRouter),
            address(donateRouter),
            address(manager)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            currency0.approve(toApprove[i], type(uint256).max);
            currency1.approve(toApprove[i], type(uint256).max);
        }

        return (currency0, currency1);
    }

    function deployAndApprovePosm(PoolManager) internal {
        // Simplified for basic testing without PositionManager complexity
        // This avoids the permit2 dependencies for now
    }
}