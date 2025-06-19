# ShieldFi: MEV-Protected Lending Hook

ShieldFi is a comprehensive MEV (Maximal Extractable Value) protection system built as a Uniswap v4 hook, providing advanced lending infrastructure with integrated MEV detection and gradual liquidation mechanisms.

## 🛡️ Overview

ShieldFi combines several cutting-edge DeFi technologies to create a robust, MEV-resistant lending platform:

- **MEV Detection Engine**: Real-time detection of sandwich attacks, front-running, and other MEV extraction attempts
- **Gradual Liquidation System**: Minimizes MEV extraction during liquidations through time-distributed execution
- **Circle USDC Integration**: Native USDC lending and borrowing with collateral management
- **EigenLayer AVS Integration**: Decentralized validation network for enhanced security
- **Uniswap v4 Hook Architecture**: Seamless integration with the latest AMM technology

## 🏗️ Architecture

### Core Components

1. **ShieldFiHook**: Main hook contract that integrates with Uniswap v4 pools
2. **MEVDetector**: Advanced MEV detection and risk assessment engine
3. **CircleUSDCVault**: USDC lending infrastructure with collateral management
4. **GradualLiquidator**: Time-distributed liquidation system to minimize MEV
5. **EigenLayerAVS**: Validator network integration for decentralized security

### Key Features

- **Multi-tier Protection**: Standard and Premium protection levels
- **Real-time MEV Detection**: Sandwich attack, HFT, and timing attack detection
- **Health Factor Monitoring**: Continuous position health assessment
- **Emergency Controls**: Pause mechanisms and emergency liquidation
- **Fee Management**: Flexible fee structure for different protection levels

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Node.js and npm/yarn
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/shieldfi-hook.git
cd shieldfi-hook

# Install dependencies
forge install

# Build the project
forge build
```

### Testing

```bash
# Run all tests
forge test

# Run tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-contract ShieldFiHookTest

# Run with gas reporting
forge test --gas-report
```

### Deployment

1. **Configure Environment**:
   ```bash
   cp .env.example .env
   # Edit .env with your configuration
   ```

2. **Update Deployment Script**:
   Edit `script/Deploy.s.sol` to set the correct addresses for your target network:
   - Pool Manager address
   - USDC token address
   - Emergency admin address

3. **Deploy to Network**:
   ```bash
   # Deploy to Sepolia testnet
   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

   # Deploy to mainnet (be careful!)
   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
   ```

## 📋 Contract Interfaces

### ShieldFiHook

Main hook contract providing MEV protection for Uniswap v4 pools.

```solidity
// Register for MEV protection
function registerProtection(ProtectionLevel level) external payable;

// Check user protection status
function getUserProtection(address user) external view returns (
    ProtectionLevel level,
    uint256 feePaid,
    bool isActive,
    uint256 lastUpdate
);
```

### MEVDetector

Advanced MEV detection engine with configurable thresholds.

```solidity
// Detect MEV attempts
function detectMEV(address user, uint256 amount, uint256 timestamp) 
    external view returns (MEVAnalysis memory);

// Flag suspicious liquidations
function flagLiquidation(address borrower, uint256 healthFactor, uint256 amount) 
    external returns (bool shouldDelay);
```

### CircleUSDCVault

USDC lending infrastructure with collateral management.

```solidity
// Deposit USDC
function deposit(uint256 amount) external;

// Borrow against collateral
function borrow(uint256 amount) external;

// Deposit collateral
function depositCollateral(address asset, uint256 amount) external;

// Get user position
function getUserPosition(address user) external view returns (UserPosition memory);
```

### GradualLiquidator

Time-distributed liquidation system to minimize MEV extraction.

```solidity
// Start gradual liquidation
function liquidateGradually(address borrower, uint256 amount, uint256 maxChunks) 
    external returns (bytes32 liquidationId);

// Execute next liquidation chunk
function executeNextChunk(bytes32 liquidationId) external returns (bool completed);
```

## 🔧 Configuration

### MEV Detection Thresholds

```solidity
// Sandwich attack detection (price impact %)
mevDetector.updateDetectionThreshold("sandwich_threshold", 50); // 5%

// High-frequency trading detection (tx per block)
mevDetector.updateDetectionThreshold("hft_threshold", 10);

// Large transaction threshold (USDC amount)
mevDetector.updateDetectionThreshold("large_tx_threshold", 100000e6); // $100k

// Timing attack detection (blocks)
mevDetector.updateDetectionThreshold("timing_threshold", 2);
```

### Protection Fees

```solidity
// Set protection fees
hook.setProtectionFee(ProtectionLevel.STANDARD, 0.001 ether);
hook.setProtectionFee(ProtectionLevel.PREMIUM, 0.005 ether);
```

### Collateral Assets

```solidity
// Add collateral asset
vault.addCollateralAsset(
    wethAddress,
    8000, // 80% collateral factor
    8500, // 85% liquidation threshold
    500,  // 5% liquidation penalty
    oracleAddress
);
```

## 🧪 Testing Strategy

### Unit Tests

- Individual contract functionality
- Edge cases and error conditions
- Access control and permissions

### Integration Tests

- Cross-contract interactions
- MEV detection scenarios
- Liquidation workflows

### Scenario Tests

- Sandwich attack protection
- Gradual liquidation execution
- Emergency pause scenarios

## 🔒 Security Considerations

### Access Control

- **Owner**: Can update system parameters and emergency controls
- **Emergency Admin**: Can pause/unpause system in emergencies
- **Authorized Liquidators**: Can execute liquidations
- **Whitelisted Addresses**: Exempt from certain MEV protections

### Risk Mitigation

- **Reentrancy Protection**: All external calls protected
- **Integer Overflow**: SafeMath and Solidity 0.8+ protections
- **Oracle Manipulation**: Multiple oracle sources and sanity checks
- **Flash Loan Attacks**: Detection and prevention mechanisms

### Emergency Procedures

1. **System Pause**: Immediate halt of all operations
2. **Emergency Liquidation**: Fast-track liquidation for critical positions
3. **Parameter Updates**: Quick adjustment of risk parameters
4. **Whitelist Management**: Rapid response to false positives

## 📊 Monitoring and Analytics

### Key Metrics

- MEV attempts detected and prevented
- Protection fee revenue
- Liquidation efficiency
- User adoption rates
- System health indicators

### Events and Logging

All major operations emit events for monitoring:

```solidity
event MEVDetected(address indexed user, uint256 riskLevel, string attackType);
event ProtectionActivated(address indexed user, ProtectionLevel level);
event LiquidationStarted(bytes32 indexed liquidationId, address indexed borrower);
event EmergencyAction(string action, address indexed admin);
```

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

### Development Workflow

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

### Code Standards

- Follow Solidity style guide
- Add comprehensive comments
- Include unit tests for new features
- Update documentation as needed

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Links

- [Documentation](https://docs.shieldfi.io)
- [Discord Community](https://discord.gg/shieldfi)
- [Twitter](https://twitter.com/shieldfi)
- [Blog](https://blog.shieldfi.io)

## ⚠️ Disclaimer

This software is experimental and provided "as is" without warranties. Use at your own risk. Always conduct thorough testing and audits before deploying to mainnet.

## 🙏 Acknowledgments

- Uniswap Labs for v4 architecture
- OpenZeppelin for security libraries
- EigenLayer for AVS infrastructure
- Circle for USDC integration
- The broader DeFi community for inspiration and feedback

---

**Built with ❤️ by the ShieldFi Team**

