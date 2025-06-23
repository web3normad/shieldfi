// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {MEVDetectionEngine} from "./MEVDetectionEngine.sol";
import {ShieldFiHook} from "./ShieldFiHook.sol";

/**
 * @title ShieldFiAVS
 * @notice EigenLayer Actively Validated Service for MEV protection and fair sequencing
 * @dev Implements validator registration, transaction validation, slashing conditions, and reward distribution
 * @author ShieldFi Protocol
 */
contract ShieldFiAVS is Ownable, ReentrancyGuard, Pausable {
    using ECDSA for bytes32;

    // ============ Constants ============
    
    /// @notice Maximum number of validators per operator set
    uint256 public constant MAX_VALIDATORS_PER_SET = 100;
    
    /// @notice Minimum stake required for validator registration (32 ETH equivalent)
    uint256 public constant MIN_VALIDATOR_STAKE = 32 ether;
    
    /// @notice Slashing percentage for malicious behavior (10%)
    uint256 public constant SLASHING_PERCENTAGE = 1000; // 10% in basis points
    
    /// @notice Reward distribution percentage (5%)
    uint256 public constant REWARD_PERCENTAGE = 500; // 5% in basis points
    
    /// @notice Fair sequencing window (12 seconds)
    uint32 public constant SEQUENCING_WINDOW = 12;
    
    /// @notice Validation timeout (30 seconds)
    uint32 public constant VALIDATION_TIMEOUT = 30;

    // ============ Structs ============
    
    /// @notice Validator information
    struct ValidatorInfo {
        address operator;           // Operator address
        uint256 stake;             // Staked amount
        uint32 registrationTime;   // Registration timestamp
        bool isActive;             // Active status
        uint256 performanceScore;  // Performance score (0-10000)
        uint256 totalRewards;      // Total rewards earned
        uint256 slashedAmount;     // Total slashed amount
        bytes32 metadataURI;       // Metadata URI hash
    }
    
    /// @notice Operator set configuration
    struct OperatorSet {
        string name;               // Set name
        uint256 minStake;          // Minimum stake requirement
        uint256 maxValidators;     // Maximum validators in set
        uint256 currentValidators; // Current validator count
        bool isActive;             // Set status
        bytes32 slashingConditions; // Slashing conditions hash
        mapping(address => bool) validators; // Validator membership
    }
    
    /// @notice Transaction validation request
    struct ValidationRequest {
        bytes32 requestId;         // Unique request ID
        address requester;         // Request originator
        bytes32 transactionHash;   // Transaction to validate
        uint32 deadline;           // Validation deadline
        uint256 requiredValidators; // Required validator count
        uint256 currentValidations; // Current validation count
        bool isCompleted;          // Completion status
        bool isValid;              // Validation result
        mapping(address => bool) validatorResponses; // Validator responses
    }
    
    /// @notice Slashing condition
    struct SlashingCondition {
        bytes32 conditionId;       // Condition identifier
        string description;        // Human-readable description
        uint256 slashingAmount;    // Amount to slash
        bool isActive;             // Condition status
        uint32 createdAt;          // Creation timestamp
    }
    
    /// @notice Fair sequencing batch
    struct SequencingBatch {
        bytes32 batchId;           // Batch identifier
        address[] transactions;    // Transaction addresses
        uint32 sequenceNumber;     // Sequence number
        uint32 timestamp;          // Batch timestamp
        address sequencer;         // Selected sequencer
        bool isFinalized;          // Finalization status
    }

    // ============ State Variables ============
    
    /// @notice ShieldFi integration
    ShieldFiHook public shieldFiHook;
    
    /// @notice Validator management
    mapping(address => ValidatorInfo) public validators;
    mapping(uint256 => OperatorSet) public operatorSets;
    mapping(bytes32 => ValidationRequest) public validationRequests;
    mapping(bytes32 => SlashingCondition) public slashingConditions;
    mapping(bytes32 => SequencingBatch) public sequencingBatches;
    
    /// @notice Validator selection and sequencing
    address[] public activeValidators;
    mapping(address => uint256) public validatorIndices;
    uint256 public currentSequenceNumber;
    
    /// @notice Reward and slashing tracking
    mapping(address => uint256) public pendingRewards;
    mapping(address => uint256) public totalSlashed;
    uint256 public totalRewardsDistributed;
    uint256 public totalAmountSlashed;
    
    /// @notice Configuration
    uint256 public operatorSetCount;
    uint256 public validationRequestCount;
    uint256 public slashingConditionCount;
    bool public fairSequencingEnabled;

    // ============ Events ============
    
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

    // ============ Errors ============
    
    error InvalidOperator();
    error InsufficientStake();
    error ValidatorNotRegistered();
    error OperatorSetNotFound();
    error ValidationRequestNotFound();
    error ValidationTimeout();
    error InvalidValidationRequest();
    error SlashingConditionNotFound();
    error UnauthorizedValidator();
    error InvalidSequencingBatch();
    error FairSequencingDisabled();

    // ============ Constructor ============
    
    constructor(address _owner) Ownable(_owner) {
        // Enable fair sequencing by default
        fairSequencingEnabled = true;
    }

    // ============ Validator Registration ============
    
    /**
     * @notice Register a validator with the AVS
     * @param operatorSetId Operator set to join
     * @param stake Amount to stake
     * @param metadataURI Metadata URI for the validator
     */
    function registerValidator(
        uint256 operatorSetId,
        uint256 stake,
        bytes32 metadataURI
    ) external payable nonReentrant whenNotPaused {
        if (msg.value < MIN_VALIDATOR_STAKE) revert InsufficientStake();
        if (stake < MIN_VALIDATOR_STAKE) revert InsufficientStake();
        
        OperatorSet storage operatorSet = operatorSets[operatorSetId];
        if (!operatorSet.isActive) revert OperatorSetNotFound();
        if (operatorSet.currentValidators >= operatorSet.maxValidators) revert InvalidOperator();
        if (stake < operatorSet.minStake) revert InsufficientStake();
        
        // Create validator info
        validators[msg.sender] = ValidatorInfo({
            operator: msg.sender,
            stake: msg.value,
            registrationTime: uint32(block.timestamp),
            isActive: true,
            performanceScore: 10000, // Start with perfect score
            totalRewards: 0,
            slashedAmount: 0,
            metadataURI: metadataURI
        });
        
        // Add to operator set
        operatorSet.validators[msg.sender] = true;
        operatorSet.currentValidators++;
        
        // Add to active validators list
        activeValidators.push(msg.sender);
        validatorIndices[msg.sender] = activeValidators.length - 1;
        
        emit ValidatorRegistered(msg.sender, msg.value, operatorSetId);
    }
    
    /**
     * @notice Deregister a validator from the AVS
     * @param operatorSetId Operator set to leave
     */
    function deregisterValidator(uint256 operatorSetId) external nonReentrant {
        ValidatorInfo storage validator = validators[msg.sender];
        if (!validator.isActive) revert ValidatorNotRegistered();
        
        OperatorSet storage operatorSet = operatorSets[operatorSetId];
        if (!operatorSet.validators[msg.sender]) revert InvalidOperator();
        
        // Update validator status
        validator.isActive = false;
        
        // Remove from operator set
        operatorSet.validators[msg.sender] = false;
        operatorSet.currentValidators--;
        
        // Remove from active validators list
        _removeFromActiveValidators(msg.sender);
        
        // Return stake
        payable(msg.sender).transfer(validator.stake);
        
        emit ValidatorDeregistered(msg.sender, operatorSetId);
    }

    // ============ Transaction Validation ============
    
    /**
     * @notice Request transaction validation from validators
     * @param transactionHash Hash of transaction to validate
     * @param requiredValidators Number of validators required
     * @return requestId Unique request identifier
     */
    function requestValidation(
        bytes32 transactionHash,
        uint256 requiredValidators
    ) external nonReentrant whenNotPaused returns (bytes32 requestId) {
        if (requiredValidators == 0 || requiredValidators > activeValidators.length) {
            revert InvalidValidationRequest();
        }
        
        requestId = keccak256(abi.encodePacked(
            msg.sender,
            transactionHash,
            block.timestamp,
            validationRequestCount++
        ));
        
        ValidationRequest storage request = validationRequests[requestId];
        request.requestId = requestId;
        request.requester = msg.sender;
        request.transactionHash = transactionHash;
        request.deadline = uint32(block.timestamp + VALIDATION_TIMEOUT);
        request.requiredValidators = requiredValidators;
        request.currentValidations = 0;
        request.isCompleted = false;
        request.isValid = false;
        
        emit ValidationRequested(requestId, msg.sender, transactionHash);
        
        return requestId;
    }
    
    /**
     * @notice Submit validation response
     * @param requestId Validation request ID
     * @param isValid Validation result
     * @param signature Validator signature
     */
    function submitValidation(
        bytes32 requestId,
        bool isValid,
        bytes calldata signature
    ) external nonReentrant {
        ValidationRequest storage request = validationRequests[requestId];
        if (request.requestId == bytes32(0)) revert ValidationRequestNotFound();
        if (request.isCompleted) revert InvalidValidationRequest();
        if (block.timestamp > request.deadline) revert ValidationTimeout();
        
        ValidatorInfo storage validator = validators[msg.sender];
        if (!validator.isActive) revert ValidatorNotRegistered();
        if (request.validatorResponses[msg.sender]) revert InvalidValidationRequest();
        
        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(requestId, isValid));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        if (ethSignedMessageHash.recover(signature) != msg.sender) revert UnauthorizedValidator();
        
        // Record validation
        request.validatorResponses[msg.sender] = true;
        request.currentValidations++;
        
        // Update validator performance score
        _updateValidatorPerformance(msg.sender, true);
        
        // Check if validation is complete
        if (request.currentValidations >= request.requiredValidators) {
            request.isCompleted = true;
            request.isValid = isValid;
            
            // Distribute rewards to validators
            _distributeValidationRewards(requestId);
            
            emit ValidationCompleted(requestId, isValid, request.currentValidations);
        }
    }

    // ============ Slashing Conditions ============
    
    /**
     * @notice Add a new slashing condition
     * @param description Human-readable description
     * @param slashingAmount Amount to slash for this condition
     * @return conditionId Unique condition identifier
     */
    function addSlashingCondition(
        string calldata description,
        uint256 slashingAmount
    ) external onlyOwner returns (bytes32 conditionId) {
        conditionId = keccak256(abi.encodePacked(
            description,
            slashingAmount,
            block.timestamp,
            slashingConditionCount++
        ));
        
        slashingConditions[conditionId] = SlashingCondition({
            conditionId: conditionId,
            description: description,
            slashingAmount: slashingAmount,
            isActive: true,
            createdAt: uint32(block.timestamp)
        });
        
        emit SlashingConditionAdded(conditionId, description, slashingAmount);
        
        return conditionId;
    }
    
    /**
     * @notice Slash a validator for malicious behavior
     * @param operator Validator to slash
     * @param conditionId Slashing condition that was violated
     * @param evidence Evidence of malicious behavior
     */
    function slashValidator(
        address operator,
        bytes32 conditionId,
        bytes calldata evidence
    ) external onlyOwner nonReentrant {
        ValidatorInfo storage validator = validators[operator];
        if (!validator.isActive) revert ValidatorNotRegistered();
        
        SlashingCondition storage condition = slashingConditions[conditionId];
        if (!condition.isActive) revert SlashingConditionNotFound();
        
        uint256 slashingAmount = condition.slashingAmount;
        if (slashingAmount > validator.stake) {
            slashingAmount = validator.stake;
        }
        
        // Update validator info
        validator.slashedAmount += slashingAmount;
        validator.stake -= slashingAmount;
        validator.performanceScore = validator.performanceScore > 1000 ? 
            validator.performanceScore - 1000 : 0;
        
        // Update global tracking
        totalSlashed[operator] += slashingAmount;
        totalAmountSlashed += slashingAmount;
        
        // Deactivate validator if stake is too low
        if (validator.stake < MIN_VALIDATOR_STAKE) {
            validator.isActive = false;
            _removeFromActiveValidators(operator);
        }
        
        emit ValidatorSlashed(operator, slashingAmount, conditionId);
    }

    // ============ Reward Distribution ============
    
    /**
     * @notice Distribute rewards to validators
     * @param validators_ Array of validator addresses
     * @param amounts Array of reward amounts
     */
    function distributeRewards(
        address[] calldata validators_,
        uint256[] calldata amounts
    ) external onlyOwner nonReentrant {
        if (validators_.length != amounts.length) revert InvalidValidationRequest();
        
        for (uint256 i = 0; i < validators_.length; i++) {
            ValidatorInfo storage validator = validators[validators_[i]];
            if (validator.isActive) {
                validator.totalRewards += amounts[i];
                pendingRewards[validators_[i]] += amounts[i];
                totalRewardsDistributed += amounts[i];
                
                emit RewardsDistributed(validators_[i], amounts[i]);
            }
        }
    }
    
    /**
     * @notice Claim pending rewards
     */
    function claimRewards() external nonReentrant {
        uint256 reward = pendingRewards[msg.sender];
        if (reward > 0) {
            pendingRewards[msg.sender] = 0;
            payable(msg.sender).transfer(reward);
        }
    }

    // ============ Fair Sequencing ============
    
    /**
     * @notice Create a fair sequencing batch
     * @param transactions Array of transaction addresses
     * @return batchId Unique batch identifier
     */
    function createSequencingBatch(
        address[] calldata transactions
    ) external nonReentrant whenNotPaused returns (bytes32 batchId) {
        if (!fairSequencingEnabled) revert FairSequencingDisabled();
        
        // Select sequencer using validator selection algorithm
        address sequencer = _selectSequencer();
        
        batchId = keccak256(abi.encodePacked(
            transactions,
            currentSequenceNumber,
            block.timestamp,
            sequencer
        ));
        
        SequencingBatch storage batch = sequencingBatches[batchId];
        batch.batchId = batchId;
        batch.transactions = transactions;
        batch.sequenceNumber = uint32(currentSequenceNumber++);
        batch.timestamp = uint32(block.timestamp);
        batch.sequencer = sequencer;
        batch.isFinalized = false;
        
        emit SequencingBatchCreated(batchId, sequencer, batch.sequenceNumber);
        
        return batchId;
    }
    
    /**
     * @notice Finalize a sequencing batch
     * @param batchId Batch to finalize
     */
    function finalizeSequencingBatch(bytes32 batchId) external nonReentrant {
        SequencingBatch storage batch = sequencingBatches[batchId];
        if (batch.batchId == bytes32(0)) revert InvalidSequencingBatch();
        if (batch.sequencer != msg.sender) revert UnauthorizedValidator();
        if (batch.isFinalized) revert InvalidSequencingBatch();
        
        batch.isFinalized = true;
        
        // Reward the sequencer
        _rewardSequencer(batch.sequencer);
    }

    // ============ Operator Set Management ============
    
    /**
     * @notice Create a new operator set
     * @param name Set name
     * @param minStake Minimum stake requirement
     * @param maxValidators Maximum validators in set
     * @param slashingConditionsHash Hash of slashing conditions
     * @return setId Unique set identifier
     */
    function createOperatorSet(
        string calldata name,
        uint256 minStake,
        uint256 maxValidators,
        bytes32 slashingConditionsHash
    ) external onlyOwner returns (uint256 setId) {
        setId = operatorSetCount++;
        
        OperatorSet storage operatorSet = operatorSets[setId];
        operatorSet.name = name;
        operatorSet.minStake = minStake;
        operatorSet.maxValidators = maxValidators;
        operatorSet.currentValidators = 0;
        operatorSet.isActive = true;
        operatorSet.slashingConditions = slashingConditionsHash;
        
        emit OperatorSetCreated(setId, name, minStake);
        
        return setId;
    }

    // ============ Integration Functions ============
    
    /**
     * @notice Set the ShieldFi Hook integration
     * @param _shieldFiHook ShieldFi Hook contract address
     */
    function setShieldFiHook(ShieldFiHook _shieldFiHook) external onlyOwner {
        shieldFiHook = _shieldFiHook;
    }
    
    /**
     * @notice Toggle fair sequencing
     * @param enabled Whether to enable fair sequencing
     */
    function toggleFairSequencing(bool enabled) external onlyOwner {
        fairSequencingEnabled = enabled;
        emit FairSequencingToggled(enabled);
    }
    
    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============
    
    /**
     * @notice Get validator information
     * @param operator Validator address
     * @return ValidatorInfo struct
     */
    function getValidatorInfo(address operator) external view returns (ValidatorInfo memory) {
        return validators[operator];
    }
    
    /**
     * @notice Get active validator count
     * @return Number of active validators
     */
    function getActiveValidatorCount() external view returns (uint256) {
        return activeValidators.length;
    }
    
    /**
     * @notice Get validation request status
     * @param requestId Request identifier
     * @return ValidationRequest struct
     */
    function getValidationRequest(bytes32 requestId) external view returns (
        bytes32,
        address,
        bytes32,
        uint32,
        uint256,
        uint256,
        bool,
        bool
    ) {
        ValidationRequest storage request = validationRequests[requestId];
        return (
            request.requestId,
            request.requester,
            request.transactionHash,
            request.deadline,
            request.requiredValidators,
            request.currentValidations,
            request.isCompleted,
            request.isValid
        );
    }

    // ============ Internal Functions ============
    
    /**
     * @notice Remove validator from active validators list
     * @param operator Validator to remove
     */
    function _removeFromActiveValidators(address operator) internal {
        uint256 index = validatorIndices[operator];
        uint256 lastIndex = activeValidators.length - 1;
        
        if (index != lastIndex) {
            address lastValidator = activeValidators[lastIndex];
            activeValidators[index] = lastValidator;
            validatorIndices[lastValidator] = index;
        }
        
        activeValidators.pop();
        delete validatorIndices[operator];
    }
    
    /**
     * @notice Update validator performance score
     * @param operator Validator address
     * @param successful Whether the validation was successful
     */
    function _updateValidatorPerformance(address operator, bool successful) internal {
        ValidatorInfo storage validator = validators[operator];
        
        if (successful) {
            // Increase performance score (max 10000)
            validator.performanceScore = validator.performanceScore < 10000 ? 
                validator.performanceScore + 10 : 10000;
        } else {
            // Decrease performance score (min 0)
            validator.performanceScore = validator.performanceScore > 50 ? 
                validator.performanceScore - 50 : 0;
        }
    }
    
    /**
     * @notice Distribute rewards for validation
     * @param requestId Validation request ID
     */
    function _distributeValidationRewards(bytes32 requestId) internal {
        ValidationRequest storage request = validationRequests[requestId];
        uint256 rewardPerValidator = (address(this).balance * REWARD_PERCENTAGE) / 
            (10000 * request.currentValidations);
        
        // Distribute rewards to participating validators
        for (uint256 i = 0; i < activeValidators.length; i++) {
            address validator = activeValidators[i];
            if (request.validatorResponses[validator]) {
                pendingRewards[validator] += rewardPerValidator;
                validators[validator].totalRewards += rewardPerValidator;
            }
        }
        
        totalRewardsDistributed += rewardPerValidator * request.currentValidations;
    }
    
    /**
     * @notice Select sequencer using validator selection algorithm
     * @return Selected sequencer address
     */
    function _selectSequencer() internal view returns (address) {
        if (activeValidators.length == 0) return address(0);
        
        // Use weighted random selection based on stake and performance
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            totalWeight += validator.stake * validator.performanceScore / 10000;
        }
        
        if (totalWeight == 0) return activeValidators[0];
        
        uint256 randomValue = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            currentSequenceNumber
        ))) % totalWeight;
        
        uint256 currentWeight = 0;
        for (uint256 i = 0; i < activeValidators.length; i++) {
            ValidatorInfo storage validator = validators[activeValidators[i]];
            currentWeight += validator.stake * validator.performanceScore / 10000;
            if (randomValue < currentWeight) {
                return activeValidators[i];
            }
        }
        
        return activeValidators[0]; // Fallback
    }
    
    /**
     * @notice Reward sequencer for batch finalization
     * @param sequencer Sequencer address
     */
    function _rewardSequencer(address sequencer) internal {
        uint256 reward = (address(this).balance * REWARD_PERCENTAGE) / 10000;
        pendingRewards[sequencer] += reward;
        validators[sequencer].totalRewards += reward;
        totalRewardsDistributed += reward;
        
        emit RewardsDistributed(sequencer, reward);
    }

    // ============ Receive Function ============
    
    receive() external payable {
        // Allow contract to receive ETH for rewards
    }
} 