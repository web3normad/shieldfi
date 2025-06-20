// ============ test/utils/Fixtures.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IExttload} from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
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

// Minimal mock PoolManager that implements only what we need for testing
contract MockPoolManager {
    using PoolIdLibrary for PoolKey;
    
    mapping(PoolId => bool) public poolInitialized;
    
    function initialize(PoolKey memory key, uint160) external returns (int24) {
        PoolId id = key.toId();
        poolInitialized[id] = true;
        return 0;
    }
    
    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory result) = msg.sender.call(
            abi.encodeWithSelector(bytes4(keccak256("unlockCallback(bytes)")), data)
        );
        require(success, "Unlock callback failed");
        return result;
    }
    
    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory,
        bytes calldata
    ) external pure returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        return (BalanceDelta.wrap(int256(1e18)), BalanceDelta.wrap(0));
    }
    
    function swap(
        PoolKey memory,
        SwapParams memory,
        bytes calldata
    ) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(int256(1e18));
    }
    
    function take(Currency, address, uint256) external pure {}
    function settle() external pure returns (uint256) { return 0; }
}

contract Fixtures is Test {
    MockPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolDonateTest donateRouter;

    TestToken currency0;
    TestToken currency1;

    function deployFreshManagerAndRouters() internal {
        // Use our lightweight MockPoolManager
        manager = new MockPoolManager();
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        donateRouter = new PoolDonateTest(IPoolManager(address(manager)));
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

    function deployAndApprovePosm(IPoolManager) internal {
        // Simplified for basic testing without PositionManager complexity
        // This avoids the permit2 dependencies for now
    }
}