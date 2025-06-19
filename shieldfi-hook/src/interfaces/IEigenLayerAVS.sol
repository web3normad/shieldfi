// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IEigenLayerAVS
 * @notice Interface for EigenLayer AVS integration
 * @dev Connects to EigenLayer for cryptoeconomic security and fair sequencing
 */
interface IEigenLayerAVS {
    // =============================================================
    //                        STRUCTS
    // =============================================================

    struct Validator {
        address validatorAddress;
        uint256 stake;
        uint256 reputation;
        bool isActive;
        uint256 lastSlashTime;
        uint256 totalValidations;
        uint256 successfulValidations;
    }

    struct ValidationRequest {
        bytes32 transactionHash;
        address requester;
        bytes validationData;
        uint256 timestamp;
        uint256 deadline;
        bool completed;
        bool approved;
        address assignedValidator;
    }

    struct SlashingCondition {
        string conditionType;        // "MEV_COLLUSION", "FALSE_VALIDATION", etc.
        uint256 slashAmount;         // Amount to slash in wei
        uint256 evidenceThreshold;   // Required evidence strength
        bool isActive;
    }

    // =============================================================
    //                        EVENTS
    // =============================================================

    event ValidatorRegistered(
        address indexed validator,
        uint256 stake,
        uint256 timestamp
    );

    event ValidatorSlashed(
        address indexed validator,
        uint256 slashAmount,
        string reason,
        bytes evidence
    );

    event ValidationRequested(
        bytes32 indexed requestId,
        bytes32 indexed transactionHash,
        address indexed requester,
        address assignedValidator
    );

    event ValidationCompleted(
        bytes32 indexed requestId,
        address indexed validator,
        bool approved,
        uint256 timestamp
    );

    event ValidatorRewardDistributed(
        address indexed validator,
        uint256 amount,
        bytes32 indexed requestId
    );

    event SlashingConditionUpdated(
        string conditionType,
        uint256 slashAmount,
        uint256 evidenceThreshold
    );

    // =============================================================
    //                        FUNCTIONS
    // =============================================================

    /**
     * @notice Submit transaction for validator verification
     * @param transactionHash Hash of the transaction to validate
     * @param validationData Additional data for validation
     * @return requestId Unique identifier for this validation request
     */
    function submitToValidator(
        bytes32 transactionHash,
        bytes calldata validationData
    ) external returns (bytes32 requestId);

    /**
     * @notice Validator submits validation result
     * @param requestId Validation request identifier
     * @param approved Whether the transaction is approved
     * @param evidence Supporting evidence for the decision
     */
    function submitValidation(
        bytes32 requestId,
        bool approved,
        bytes calldata evidence
    ) external;

    /**
     * @notice Slash a malicious validator
     * @param validator Address of validator to slash
     * @param proof Evidence of malicious behavior
     * @param conditionType Type of slashing condition violated
     */
    function slashMaliciousValidator(
        address validator,
        bytes calldata proof,
        string calldata conditionType
    ) external;

    /**
     * @notice Register as a validator (requires stake)
     * @param stake Amount to stake in wei
     */
    function registerValidator(uint256 stake) external payable;

    /**
     * @notice Unregister as validator and withdraw stake
     */
    function unregisterValidator() external;

    /**
     * @notice Increase validator stake
     */
    function increaseStake() external payable;

    /**
     * @notice Withdraw validator rewards
     */
    function withdrawRewards() external;

    /**
     * @notice Get validator information
     * @param validator Validator address
     * @return validatorInfo Validator details
     */
    function getValidator(address validator) external view returns (Validator memory validatorInfo);

    /**
     * @notice Get validation request details
     * @param requestId Request identifier
     * @return request Validation request details
     */
    function getValidationRequest(bytes32 requestId) external view returns (ValidationRequest memory request);

    /**
     * @notice Get available validators for assignment
     * @param minStake Minimum stake required
     * @param minReputation Minimum reputation required
     * @return validators Array of available validator addresses
     */
    function getAvailableValidators(uint256 minStake, uint256 minReputation) 
        external view returns (address[] memory validators);

    /**
     * @notice Calculate validator selection probability
     * @param validator Validator address
     * @return probability Selection probability (0-10000 basis points)
     */
    function getValidatorProbability(address validator) external view returns (uint256 probability);

    /**
     * @notice Get validator rewards balance
     * @param validator Validator address
     * @return rewards Available rewards in wei
     */
    function getValidatorRewards(address validator) external view returns (uint256 rewards);

    /**
     * @notice Check if validator is eligible for assignment
     * @param validator Validator address
     * @return eligible Whether validator can be assigned new requests
     */
    function isValidatorEligible(address validator) external view returns (bool eligible);

    /**
     * @notice Get slashing condition details
     * @param conditionType Type of slashing condition
     * @return condition Slashing condition details
     */
    function getSlashingCondition(string calldata conditionType) 
        external view returns (SlashingCondition memory condition);

    /**
     * @notice Update slashing conditions (admin only)
     * @param conditionType Type of condition to update
     * @param slashAmount Amount to slash
     * @param evidenceThreshold Required evidence threshold
     */
    function updateSlashingCondition(
        string calldata conditionType,
        uint256 slashAmount,
        uint256 evidenceThreshold
    ) external;

    /**
     * @notice Get total staked amount across all validators
     * @return totalStake Total stake in the system
     */
    function getTotalStake() external view returns (uint256 totalStake);

    /**
     * @notice Get number of active validators
     * @return count Number of active validators
     */
    function getActiveValidatorCount() external view returns (uint256 count);

    /**
     * @notice Get validation statistics
     * @return totalRequests Total validation requests
     * @return completedRequests Completed validation requests
     * @return averageResponseTime Average response time in seconds
     */
    function getValidationStats() external view returns (
        uint256 totalRequests,
        uint256 completedRequests,
        uint256 averageResponseTime
    );

    /**
     * @notice Emergency pause validator operations
     */
    function pauseValidations() external;

    /**
     * @notice Resume validator operations
     */
    function resumeValidations() external;

    /**
     * @notice Check if validations are currently paused
     * @return paused Whether validations are paused
     */
    function isValidationsPaused() external view returns (bool paused);
} 