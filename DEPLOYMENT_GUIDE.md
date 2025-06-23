# 🚀 ShieldFi Deployment Guide

This guide explains how to deploy and configure the complete ShieldFi MEV protection system.

## 📋 Prerequisites

### Required Tools
```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install jq for JSON parsing
sudo apt install jq  # Ubuntu/Debian
brew install jq      # macOS
```

### Required Accounts & Keys
1. **Deployer Account**: Private key with ETH for gas fees
2. **Etherscan API Key**: For contract verification
3. **RPC Endpoint**: For network connectivity

### Minimum ETH Requirements
- **Holesky Testnet**: ~0.1 ETH for deployment
- **Mainnet**: ~0.5-1 ETH (depending on gas prices)

## 🏗️ System Components

The ShieldFi system consists of 4 main components:

1. **ShieldFiAVS** - EigenLayer AVS for validation and slashing
2. **ShieldFiHook** - Uniswap V4 hook for MEV detection
3. **GradualLiquidationManager** - Manages liquidations to prevent MEV
4. **MEVDetectionEngine** - Core MEV detection logic (embedded in hook)

## 🔧 Deployment Steps

### Step 1: Environment Setup

```bash
# Clone and setup
git clone <your-repo>
cd shieldfi

# Copy environment template
cp env.example .env

# Edit .env with your values
nano .env
```

Required environment variables:
```bash
PRIVATE_KEY=0x...                    # Your deployer private key
RPC_URL=https://...                  # Your RPC endpoint
ETHERSCAN_API_KEY=...                # For contract verification
NETWORK=holesky                      # Target network
```

### Step 2: Deploy Contracts

```bash
# Make deployment script executable
chmod +x deploy.sh

# Run deployment
./deploy.sh
```

The script will:
1. ✅ Deploy ShieldFiAVS with EigenLayer integration
2. ✅ Deploy ShieldFiHook with MEV detection
3. ✅ Deploy GradualLiquidationManager
4. ✅ Configure contract integrations
5. ✅ Create default operator set
6. ✅ Save deployment addresses

### Step 3: Verify Deployment

Check the generated `deployment-addresses.json`:
```json
{
  "network": "holesky",
  "contracts": {
    "ShieldFiAVS": "0x...",
    "ShieldFiHook": "0x...",
    "GradualLiquidationManager": "0x..."
  }
}
```

## 🔄 How It Works

### User Protection Flow
```
1. User enables protection: hook.enableUserProtection{value: 1 ether}(poolId)
2. User performs swap: Uniswap V4 calls hook.beforeSwap()
3. MEV detection: Hook analyzes transaction for MEV patterns
4. If MEV detected: Penalties applied, rewards redistributed
5. Gradual liquidation: Risky positions liquidated gradually
```

### Validator Operations
```
1. Stake 32 ETH: avs.registerValidator()
2. Validate transactions: avs.submitValidation()
3. Earn rewards: avs.claimRewards()
4. Risk slashing: If malicious behavior detected
```

## 📊 Post-Deployment Configuration

### Configure Pool Protection
```bash
# Set protection for a specific Uniswap V4 pool
cast send $HOOK_ADDRESS "configureProtection((bool,uint256,uint256,uint256,uint256,uint256,address,uint32))" \
  "(true,1000000000000000000000,1000,100000000000000000000,100,500,0xTokenAddress,60)" \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

### Register Validators
```bash
# Register as a validator (requires 32 ETH stake)
cast send $AVS_ADDRESS "registerValidator(uint256,uint256,bytes32)" \
  0 32000000000000000000 0xmetadata \
  --value 32000000000000000000 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

## 🛡️ Security & Monitoring

### Check System Status
```bash
# Check active validators
cast call $AVS_ADDRESS "getActiveValidatorCount()" --rpc-url $RPC_URL

# Check user protection
cast call $HOOK_ADDRESS "isUserProtected(address,bytes32)" $USER_ADDRESS $POOL_ID --rpc-url $RPC_URL
```

For more details, see [EIGENLAYER_AVS_INTEGRATION.md](EIGENLAYER_AVS_INTEGRATION.md) 