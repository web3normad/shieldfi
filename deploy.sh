#!/bin/bash

# ShieldFi Deployment Script
# This script deploys all ShieldFi contracts in the correct order

set -e

echo "🛡️  Starting ShieldFi Deployment..."

# Load environment variables
if [ -f .env ]; then
    source .env
else
    echo "❌ .env file not found. Please create one with required variables."
    exit 1
fi

# Check required environment variables
required_vars=("PRIVATE_KEY" "RPC_URL" "ETHERSCAN_API_KEY")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Required environment variable $var is not set"
        exit 1
    fi
done

echo "✅ Environment variables loaded"

# Network configuration
NETWORK=${NETWORK:-"holesky"}
echo "🌐 Deploying to network: $NETWORK"

# Step 1: Deploy ShieldFiAVS (EigenLayer integration)
echo "📡 Deploying ShieldFiAVS..."
forge script scripts/DeployAVS.s.sol:DeployAVS \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY

# Extract address from broadcast logs (with error handling)
if [ -f broadcast/DeployAVS.s.sol/*/run-latest.json ]; then
    AVS_ADDRESS=$(ls broadcast/DeployAVS.s.sol/*/run-latest.json 2>/dev/null | head -1 | xargs cat 2>/dev/null | jq -r '.transactions[]? | select(.contractName == "ShieldFiAVS")? | .contractAddress' 2>/dev/null)
else
    echo "⚠️  Broadcast logs not found, checking deployment output..."
    AVS_ADDRESS=""
fi

if [ -z "$AVS_ADDRESS" ] || [ "$AVS_ADDRESS" == "null" ]; then
    echo "❌ Failed to deploy ShieldFiAVS"
    exit 1
fi

echo "✅ ShieldFiAVS deployed at: $AVS_ADDRESS"

# Step 2: Deploy Hook and related contracts
echo "🪝 Deploying ShieldFi Hook system..."
HOOK_DEPLOYMENT=$(forge script scripts/Deploy.s.sol:Deploy \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --json)

HOOK_ADDRESS=$(echo $HOOK_DEPLOYMENT | jq -r '.logs[] | select(.eventName == "log_named_address" and .topics[1] == "ShieldFiHook") | .topics[2]')
LIQUIDATION_MANAGER_ADDRESS=$(echo $HOOK_DEPLOYMENT | jq -r '.logs[] | select(.eventName == "log_named_address" and .topics[1] == "GradualLiquidationManager") | .topics[2]')

if [ -z "$HOOK_ADDRESS" ] || [ "$HOOK_ADDRESS" == "null" ]; then
    echo "❌ Failed to deploy Hook system"
    exit 1
fi

echo "✅ ShieldFiHook deployed at: $HOOK_ADDRESS"
echo "✅ GradualLiquidationManager deployed at: $LIQUIDATION_MANAGER_ADDRESS"

# Step 3: Configure integrations
echo "🔗 Configuring contract integrations..."

# Set Hook in AVS
cast send $AVS_ADDRESS "setShieldFiHook(address)" $HOOK_ADDRESS \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY

echo "✅ Hook integration configured in AVS"

# Step 4: Create operator set in AVS
echo "👥 Creating default operator set..."
cast send $AVS_ADDRESS "createOperatorSet(string,uint256,uint256,bytes32)" \
    "ShieldFi Main Operators" \
    "32000000000000000000" \
    "100" \
    "0x$(echo -n "ShieldFi Slashing Conditions v1.0" | xxd -p)" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY

echo "✅ Default operator set created"

# Step 5: Save deployment addresses
cat > deployment-addresses.json << EOF
{
  "network": "$NETWORK",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contracts": {
    "ShieldFiAVS": "$AVS_ADDRESS",
    "ShieldFiHook": "$HOOK_ADDRESS",
    "GradualLiquidationManager": "$LIQUIDATION_MANAGER_ADDRESS"
  },
  "configuration": {
    "minValidatorStake": "32000000000000000000",
    "maxValidators": 100,
    "mevThreshold": "1000000000000000000000",
    "redistributionRate": 1000
  }
}
EOF

echo "✅ Deployment addresses saved to deployment-addresses.json"

echo ""
echo "🎉 ShieldFi Deployment Complete!"
echo ""
echo "📋 Summary:"
echo "├── ShieldFiAVS: $AVS_ADDRESS"
echo "├── ShieldFiHook: $HOOK_ADDRESS"
echo "└── GradualLiquidationManager: $LIQUIDATION_MANAGER_ADDRESS"
echo ""
echo "🔗 Next Steps:"
echo "1. Register validators in the AVS"
echo "2. Configure pool protection settings"
echo "3. Enable user protection for specific pools"
echo ""
echo "📖 See README.md for usage instructions" 