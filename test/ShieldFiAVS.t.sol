// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ShieldFiAVS} from "../src/ShieldFiAVS.sol";
import {ShieldFiHook} from "../src/ShieldFiHook.sol";
import {MEVDetectionEngine} from "../src/MEVDetectionEngine.sol";

contract ShieldFiAVSTest is Test {
    ShieldFiAVS public avs;
    ShieldFiHook public hook;
    
    // Test addresses
    address public owner = makeAddr("owner");
    address public validator1 = makeAddr("validator1");
    address public validator2 = makeAddr("validator2");
    address public validator3 = makeAddr("validator3");
    address public user = makeAddr("user");
    
    // Test constants
    uint256 public constant MIN_STAKE = 32 ether;
    uint256 public constant OPERATOR_SET_ID = 0;
    bytes32 public constant METADATA_URI = keccak256("metadata");
    bytes32 public constant SLASHING_CONDITIONS = keccak256("conditions");
    
    // Events to test
    event ValidatorRegistered(address indexed operator, uint256 stake, uint256 operatorSetId);
    event ValidatorDeregistered(address indexed operator, uint256 operatorSetId);
    event ValidationRequested(bytes32 indexed requestId, address indexed requester, bytes32 transactionHash);
    event ValidationCompleted(bytes32 indexed requestId, bool isValid, uint256 validatorCount);
    event ValidatorSlashed(address indexed operator, uint256 amount, bytes32 reason);
    event RewardsDistributed(address indexed operator, uint256 amount);
    event OperatorSetCreated(uint256 indexed setId, string name, uint256 minStake);
    event SlashingConditionAdded(bytes32 indexed conditionId, string description, uint256 slashingAmount);
    event SequencingBatchCreated(bytes32 indexed batchId, address indexed sequencer, uint32 sequenceNumber);
    event FairSequencingToggled(bool enabled);

    function setUp() public {
        // Deploy contracts
        vm.startPrank(owner);
        avs = new ShieldFiAVS(owner);
        
        // Create default operator set
        avs.createOperatorSet(
            "Default Operator Set",
            MIN_STAKE,
            100,
            SLASHING_CONDITIONS
        );
        vm.stopPrank();
        
        // Fund test accounts
        vm.deal(validator1, 100 ether);
        vm.deal(validator2, 100 ether);
        vm.deal(validator3, 100 ether);
        vm.deal(user, 10 ether);
        vm.deal(address(avs), 50 ether); // For rewards
    }

    // ============ Validator Registration Tests ============
    
    function testValidatorRegistration() public {
        vm.startPrank(validator1);
        
        vm.expectEmit(true, true, true, true);
        emit ValidatorRegistered(validator1, MIN_STAKE, OPERATOR_SET_ID);
        
        avs.registerValidator{value: MIN_STAKE}(
            OPERATOR_SET_ID,
            MIN_STAKE,
            METADATA_URI
        );
        
        // Check validator info
        ShieldFiAVS.ValidatorInfo memory info = avs.getValidatorInfo(validator1);
        assertEq(info.operator, validator1);
        assertEq(info.stake, MIN_STAKE);
        assertTrue(info.isActive);
        assertEq(info.performanceScore, 10000);
        assertEq(info.totalRewards, 0);
        assertEq(info.slashedAmount, 0);
        assertEq(info.metadataURI, METADATA_URI);
        
        // Check active validator count
        assertEq(avs.getActiveValidatorCount(), 1);
        
        vm.stopPrank();
    }
    
    function testValidatorRegistrationInsufficientStake() public {
        vm.startPrank(validator1);
        
        vm.expectRevert(ShieldFiAVS.InsufficientStake.selector);
        avs.registerValidator{value: MIN_STAKE - 1}(
            OPERATOR_SET_ID,
            MIN_STAKE - 1,
            METADATA_URI
        );
        
        vm.stopPrank();
    }
    
    function testValidatorRegistrationInvalidOperatorSet() public {
        vm.startPrank(validator1);
        
        vm.expectRevert(ShieldFiAVS.OperatorSetNotFound.selector);
        avs.registerValidator{value: MIN_STAKE}(
            999, // Non-existent operator set
            MIN_STAKE,
            METADATA_URI
        );
        
        vm.stopPrank();
    }
    
    function testValidatorDeregistration() public {
        // First register a validator
        vm.startPrank(validator1);
        avs.registerValidator{value: MIN_STAKE}(
            OPERATOR_SET_ID,
            MIN_STAKE,
            METADATA_URI
        );
        
        uint256 balanceBefore = validator1.balance;
        
        vm.expectEmit(true, true, true, true);
        emit ValidatorDeregistered(validator1, OPERATOR_SET_ID);
        
        avs.deregisterValidator(OPERATOR_SET_ID);
        
        // Check validator is deactivated
        ShieldFiAVS.ValidatorInfo memory info = avs.getValidatorInfo(validator1);
        assertFalse(info.isActive);
        
        // Check stake is returned
        assertEq(validator1.balance, balanceBefore + MIN_STAKE);
        
        // Check active validator count
        assertEq(avs.getActiveValidatorCount(), 0);
        
        vm.stopPrank();
    }

    // ============ Transaction Validation Tests ============
    
    function testValidationRequest() public {
        // Register validators
        _registerValidators();
        
        vm.startPrank(user);
        
        bytes32 txHash = keccak256("test-transaction");
        uint256 requiredValidators = 2;
        
        vm.expectEmit(true, true, true, true);
        emit ValidationRequested(bytes32(0), user, txHash); // requestId will be generated
        
        bytes32 requestId = avs.requestValidation(txHash, requiredValidators);
        
        // Check validation request
        (
            bytes32 storedRequestId,
            address requester,
            bytes32 transactionHash,
            uint32 deadline,
            uint256 required,
            uint256 current,
            bool isCompleted,
            bool isValid
        ) = avs.getValidationRequest(requestId);
        
        assertEq(storedRequestId, requestId);
        assertEq(requester, user);
        assertEq(transactionHash, txHash);
        assertGt(deadline, block.timestamp);
        assertEq(required, requiredValidators);
        assertEq(current, 0);
        assertFalse(isCompleted);
        assertFalse(isValid);
        
        vm.stopPrank();
    }
    
    function testValidationSubmission() public {
        // Register validators and create validation request
        _registerValidators();
        
        vm.startPrank(user);
        bytes32 txHash = keccak256("test-transaction");
        bytes32 requestId = avs.requestValidation(txHash, 2);
        vm.stopPrank();
        
        // Submit validation from validator1
        vm.startPrank(validator1);
        bytes32 messageHash = keccak256(abi.encodePacked(requestId, true));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, ethSignedMessageHash); // Use private key 1
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // Note: This test assumes we can create valid signatures for testing
        // In practice, you might need to adjust signature creation
        vm.stopPrank();
    }
    
    function testValidationTimeout() public {
        // Register validators and create validation request
        _registerValidators();
        
        vm.startPrank(user);
        bytes32 txHash = keccak256("test-transaction");
        bytes32 requestId = avs.requestValidation(txHash, 2);
        vm.stopPrank();
        
        // Fast forward past timeout
        vm.warp(block.timestamp + 31); // VALIDATION_TIMEOUT is 30 seconds
        
        vm.startPrank(validator1);
        bytes32 messageHash = keccak256(abi.encodePacked(requestId, true));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ShieldFiAVS.ValidationTimeout.selector);
        avs.submitValidation(requestId, true, signature);
        
        vm.stopPrank();
    }

    // ============ Slashing Tests ============
    
    function testAddSlashingCondition() public {
        vm.startPrank(owner);
        
        string memory description = "MEV detected";
        uint256 slashingAmount = 1 ether;
        
        vm.expectEmit(true, true, true, true);
        emit SlashingConditionAdded(bytes32(0), description, slashingAmount); // conditionId will be generated
        
        bytes32 conditionId = avs.addSlashingCondition(description, slashingAmount);
        
        assertNotEq(conditionId, bytes32(0));
        
        vm.stopPrank();
    }
    
    function testSlashValidator() public {
        // Register validator and add slashing condition
        _registerValidators();
        
        vm.startPrank(owner);
        string memory description = "MEV detected";
        uint256 slashingAmount = 1 ether;
        bytes32 conditionId = avs.addSlashingCondition(description, slashingAmount);
        
        vm.expectEmit(true, true, true, true);
        emit ValidatorSlashed(validator1, slashingAmount, conditionId);
        
        bytes memory evidence = "MEV evidence";
        avs.slashValidator(validator1, conditionId, evidence);
        
        // Check validator info after slashing
        ShieldFiAVS.ValidatorInfo memory info = avs.getValidatorInfo(validator1);
        assertEq(info.slashedAmount, slashingAmount);
        assertEq(info.stake, MIN_STAKE - slashingAmount);
        assertLt(info.performanceScore, 10000); // Performance score should decrease
        
        // Check global slashing tracking
        assertEq(avs.totalSlashed(validator1), slashingAmount);
        assertEq(avs.totalAmountSlashed(), slashingAmount);
        
        vm.stopPrank();
    }
    
    function testSlashValidatorDeactivation() public {
        // Register validator with minimum stake
        vm.startPrank(validator1);
        avs.registerValidator{value: MIN_STAKE}(OPERATOR_SET_ID, MIN_STAKE, METADATA_URI);
        vm.stopPrank();
        
        vm.startPrank(owner);
        // Add slashing condition that would slash entire stake
        bytes32 conditionId = avs.addSlashingCondition("Severe MEV", MIN_STAKE);
        
        bytes memory evidence = "Severe MEV evidence";
        avs.slashValidator(validator1, conditionId, evidence);
        
        // Check validator is deactivated
        ShieldFiAVS.ValidatorInfo memory info = avs.getValidatorInfo(validator1);
        assertFalse(info.isActive);
        assertEq(avs.getActiveValidatorCount(), 0);
        
        vm.stopPrank();
    }

    // ============ Reward Distribution Tests ============
    
    function testDistributeRewards() public {
        // Register validators
        _registerValidators();
        
        vm.startPrank(owner);
        
        address[] memory validators = new address[](2);
        validators[0] = validator1;
        validators[1] = validator2;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 0.5 ether;
        
        vm.expectEmit(true, true, true, true);
        emit RewardsDistributed(validator1, amounts[0]);
        vm.expectEmit(true, true, true, true);
        emit RewardsDistributed(validator2, amounts[1]);
        
        avs.distributeRewards(validators, amounts);
        
        // Check pending rewards
        assertEq(avs.pendingRewards(validator1), amounts[0]);
        assertEq(avs.pendingRewards(validator2), amounts[1]);
        
        // Check validator total rewards
        ShieldFiAVS.ValidatorInfo memory info1 = avs.getValidatorInfo(validator1);
        ShieldFiAVS.ValidatorInfo memory info2 = avs.getValidatorInfo(validator2);
        assertEq(info1.totalRewards, amounts[0]);
        assertEq(info2.totalRewards, amounts[1]);
        
        // Check global tracking
        assertEq(avs.totalRewardsDistributed(), amounts[0] + amounts[1]);
        
        vm.stopPrank();
    }
    
    function testClaimRewards() public {
        // Register validator and distribute rewards
        _registerValidators();
        
        vm.startPrank(owner);
        address[] memory validators = new address[](1);
        validators[0] = validator1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        avs.distributeRewards(validators, amounts);
        vm.stopPrank();
        
        // Claim rewards
        vm.startPrank(validator1);
        uint256 balanceBefore = validator1.balance;
        avs.claimRewards();
        
        // Check balance increased and pending rewards cleared
        assertEq(validator1.balance, balanceBefore + amounts[0]);
        assertEq(avs.pendingRewards(validator1), 0);
        
        vm.stopPrank();
    }

    // ============ Fair Sequencing Tests ============
    
    function testCreateSequencingBatch() public {
        // Register validators
        _registerValidators();
        
        vm.startPrank(user);
        
        address[] memory transactions = new address[](3);
        transactions[0] = makeAddr("tx1");
        transactions[1] = makeAddr("tx2");
        transactions[2] = makeAddr("tx3");
        
        vm.expectEmit(true, true, true, true);
        emit SequencingBatchCreated(bytes32(0), address(0), 0); // Values will be generated
        
        bytes32 batchId = avs.createSequencingBatch(transactions);
        
        assertNotEq(batchId, bytes32(0));
        
        vm.stopPrank();
    }
    
    function testFairSequencingDisabled() public {
        // Disable fair sequencing
        vm.startPrank(owner);
        avs.toggleFairSequencing(false);
        vm.stopPrank();
        
        vm.startPrank(user);
        
        address[] memory transactions = new address[](1);
        transactions[0] = makeAddr("tx1");
        
        vm.expectRevert(ShieldFiAVS.FairSequencingDisabled.selector);
        avs.createSequencingBatch(transactions);
        
        vm.stopPrank();
    }

    // ============ Operator Set Management Tests ============
    
    function testCreateOperatorSet() public {
        vm.startPrank(owner);
        
        string memory name = "Test Operator Set";
        uint256 minStake = MIN_STAKE * 2;
        uint256 maxValidators = 50;
        bytes32 conditions = keccak256("test-conditions");
        
        vm.expectEmit(true, true, true, true);
        emit OperatorSetCreated(1, name, minStake); // setId will be 1 (0 was created in setUp)
        
        uint256 setId = avs.createOperatorSet(name, minStake, maxValidators, conditions);
        
        assertEq(setId, 1);
        
        vm.stopPrank();
    }

    // ============ Integration Tests ============
    
    function testShieldFiHookIntegration() public {
        // This would test integration with ShieldFi Hook
        // For now, just test the setter
        vm.startPrank(owner);
        
        // Deploy a mock hook for testing
        address mockHook = makeAddr("mockHook");
        
        // This will fail because mockHook is not a contract, but tests the function exists
        vm.expectRevert();
        avs.setShieldFiHook(ShieldFiHook(payable(mockHook)));
        
        vm.stopPrank();
    }

    // ============ Access Control Tests ============
    
    function testOnlyOwnerFunctions() public {
        vm.startPrank(user); // Non-owner
        
        vm.expectRevert();
        avs.addSlashingCondition("test", 1 ether);
        
        vm.expectRevert();
        avs.slashValidator(validator1, bytes32(0), "evidence");
        
        address[] memory validators = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        vm.expectRevert();
        avs.distributeRewards(validators, amounts);
        
        vm.expectRevert();
        avs.createOperatorSet("test", MIN_STAKE, 100, bytes32(0));
        
        vm.expectRevert();
        avs.toggleFairSequencing(false);
        
        vm.stopPrank();
    }

    // ============ Pausable Tests ============
    
    function testPauseFunctionality() public {
        vm.startPrank(owner);
        avs.pause();
        vm.stopPrank();
        
        vm.startPrank(validator1);
        
        vm.expectRevert("Pausable: paused");
        avs.registerValidator{value: MIN_STAKE}(OPERATOR_SET_ID, MIN_STAKE, METADATA_URI);
        
        vm.stopPrank();
        
        vm.startPrank(user);
        
        vm.expectRevert("Pausable: paused");
        avs.requestValidation(keccak256("test"), 1);
        
        address[] memory transactions = new address[](1);
        vm.expectRevert("Pausable: paused");
        avs.createSequencingBatch(transactions);
        
        vm.stopPrank();
    }

    // ============ Helper Functions ============
    
    function _registerValidators() internal {
        vm.startPrank(validator1);
        avs.registerValidator{value: MIN_STAKE}(OPERATOR_SET_ID, MIN_STAKE, METADATA_URI);
        vm.stopPrank();
        
        vm.startPrank(validator2);
        avs.registerValidator{value: MIN_STAKE}(OPERATOR_SET_ID, MIN_STAKE, METADATA_URI);
        vm.stopPrank();
        
        vm.startPrank(validator3);
        avs.registerValidator{value: MIN_STAKE}(OPERATOR_SET_ID, MIN_STAKE, METADATA_URI);
        vm.stopPrank();
    }
} 