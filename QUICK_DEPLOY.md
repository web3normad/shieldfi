# 🚀 Quick Deployment Guide

## Step 1: Environment Setup

Create a `.env` file (copy from `env.example`):
```bash
cp env.example .env
# Edit .env with your values
```

Required values:
- `PRIVATE_KEY`: Your deployer private key (with 0x prefix)
- `RPC_URL`: RPC endpoint (e.g., Holesky testnet)
- `ETHERSCAN_API_KEY`: For contract verification

## Step 2: Get Testnet ETH

For Holesky testnet:
```bash
# Your deployer address
cast wallet address --private-key $PRIVATE_KEY

# Get testnet ETH from faucets:
# - https://holesky-faucet.pk910.de/
# - https://cloud.google.com/application/web3/faucet/ethereum/holesky
```

## Step 3: Manual Deployment (Recommended)

### Deploy ShieldFiAVS
```bash
forge script scripts/DeployAVS.s.sol:DeployAVS \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

### Deploy Hook System
```bash
forge script scripts/Deploy.s.sol:Deploy \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

## Step 4: Get Deployed Addresses

Check the deployment logs or broadcast files:
```bash
# Find latest deployment
ls -la broadcast/*/*/run-latest.json

# Extract addresses
cat broadcast/DeployAVS.s.sol/*/run-latest.json | jq '.transactions[] | {contractName, contractAddress}'
```

## Step 5: Configure Integration

Connect the Hook to AVS:
```bash
# Replace with your actual addresses
AVS_ADDRESS="0x..."
HOOK_ADDRESS="0x..."

cast send $AVS_ADDRESS "setShieldFiHook(address)" $HOOK_ADDRESS \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

## Step 6: Create Operator Set

```bash
cast send $AVS_ADDRESS "createOperatorSet(string,uint256,uint256,bytes32)" \
    "ShieldFi Main Operators" \
    "32000000000000000000" \
    "100" \
    "0x$(echo -n 'ShieldFi Slashing Conditions v1.0' | xxd -p)" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

## ✅ Verification

Test your deployment:
```bash
# Check AVS is deployed
cast call $AVS_ADDRESS "owner()" --rpc-url $RPC_URL

# Check Hook integration
cast call $AVS_ADDRESS "shieldFiHook()" --rpc-url $RPC_URL

# Run tests against deployed contracts
forge test --fork-url $RPC_URL
```

## 📝 Save Addresses

Create a deployment record:
```json
{
  "network": "holesky",
  "ShieldFiAVS": "0x...",
  "ShieldFiHook": "0x...",
  "GradualLiquidationManager": "0x..."
}
``` 