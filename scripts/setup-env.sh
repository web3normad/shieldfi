#!/bin/bash

# ShieldFi EigenLayer AVS Environment Setup Script
# This script sets up all necessary environment variables for deployment

echo "🛡️  ShieldFi EigenLayer AVS Environment Setup"
echo "=============================================="

# Check if .env file exists
if [ -f .env ]; then
    echo "📄 Loading existing .env file..."
    source .env
else
    echo "📝 Creating new .env file..."
fi

# Function to prompt for input with default value
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    echo -n "$prompt [$default]: "
    read input
    if [ -z "$input" ]; then
        export $var_name="$default"
    else
        export $var_name="$input"
    fi
}

# Function to generate a random private key (for testing only)
generate_test_private_key() {
    echo "0x$(openssl rand -hex 32)"
}

echo ""
echo "🔑 Setting up deployment configuration..."
echo ""

# Private Key Setup
if [ -z "$PRIVATE_KEY" ] || [ "$PRIVATE_KEY" = "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
    echo "⚠️  WARNING: You need a private key for deployment!"
    echo "Options:"
    echo "1. Enter your own private key (NEVER use mainnet keys for testing!)"
    echo "2. Generate a random test key (recommended for testing)"
    echo ""
    echo -n "Choose option (1/2) [2]: "
    read key_option
    
    if [ "$key_option" = "1" ]; then
        echo -n "Enter your private key (0x...): "
        read -s private_key_input
        echo ""
        export PRIVATE_KEY="$private_key_input"
    else
        test_key=$(generate_test_private_key)
        export PRIVATE_KEY="$test_key"
        echo "✅ Generated test private key: $test_key"
        echo "⚠️  Remember to fund this address with Holesky ETH for deployment!"
    fi
else
    echo "✅ Using existing private key"
fi

# Network Configuration
prompt_with_default "Holesky RPC URL" "https://ethereum-holesky.publicnode.com" "RPC_URL"
export HOLESKY_RPC_URL="$RPC_URL"

# API Keys
prompt_with_default "Etherscan API Key (for contract verification)" "YOUR_ETHERSCAN_API_KEY_HERE" "ETHERSCAN_API_KEY"
prompt_with_default "Arbiscan API Key" "YOUR_ARBISCAN_API_KEY_HERE" "ARBISCAN_API_KEY"

# Deployment Parameters
prompt_with_default "Minimum Validator Stake (in wei)" "32000000000000000000" "MIN_VALIDATOR_STAKE"
prompt_with_default "Maximum Validators per Set" "100" "MAX_VALIDATORS"
prompt_with_default "Operator Set Name" "ShieldFi MEV Protection Validators" "OPERATOR_SET_NAME"

# Chain Configuration
export HOLESKY_CHAIN_ID=17000
export MAINNET_CHAIN_ID=1

# Gas Configuration
export GAS_LIMIT=5000000
export GAS_PRICE=20000000000

# Deployment Settings
export VERIFY_CONTRACTS=true
export OPTIMIZER_ENABLED=true
export OPTIMIZER_RUNS=200
export EIGENLAYER_TESTNET=true

echo ""
echo "💾 Saving environment variables..."

# Create .env file
cat > .env << EOF
# ShieldFi EigenLayer AVS Environment Variables
# Generated on $(date)

# Private key for deployment
PRIVATE_KEY=$PRIVATE_KEY

# Network Configuration
RPC_URL=$RPC_URL
HOLESKY_RPC_URL=$HOLESKY_RPC_URL
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_ALCHEMY_KEY

# API Keys
ETHERSCAN_API_KEY=$ETHERSCAN_API_KEY
ARBISCAN_API_KEY=$ARBISCAN_API_KEY

# Chain IDs
HOLESKY_CHAIN_ID=$HOLESKY_CHAIN_ID
MAINNET_CHAIN_ID=$MAINNET_CHAIN_ID

# Deployment Configuration
MIN_VALIDATOR_STAKE=$MIN_VALIDATOR_STAKE
MAX_VALIDATORS=$MAX_VALIDATORS
OPERATOR_SET_NAME="$OPERATOR_SET_NAME"

# Gas Configuration
GAS_LIMIT=$GAS_LIMIT
GAS_PRICE=$GAS_PRICE

# Contract Addresses (populated after deployment)
SHIELDFI_AVS_ADDRESS=
SHIELDFI_HOOK_ADDRESS=
EIGENLAYER_CORE_ADDRESS=

# Settings
VERIFY_CONTRACTS=$VERIFY_CONTRACTS
OPTIMIZER_ENABLED=$OPTIMIZER_ENABLED
OPTIMIZER_RUNS=$OPTIMIZER_RUNS
EIGENLAYER_TESTNET=$EIGENLAYER_TESTNET
EOF

echo "✅ Environment variables saved to .env file"
echo ""

# Calculate deployer address from private key
if command -v cast >/dev/null 2>&1; then
    DEPLOYER_ADDRESS=$(cast wallet address $PRIVATE_KEY 2>/dev/null || echo "Unable to calculate address")
    echo "📍 Deployer Address: $DEPLOYER_ADDRESS"
    echo "DEPLOYER_ADDRESS=$DEPLOYER_ADDRESS" >> .env
else
    echo "⚠️  Install Foundry's 'cast' tool to see deployer address"
fi

echo ""
echo "🎯 Next Steps:"
echo "1. Fund your deployer address with Holesky ETH:"
echo "   - Get testnet ETH from: https://holesky-faucet.pk910.de/"
echo "   - Send to: $DEPLOYER_ADDRESS"
echo ""
echo "2. Deploy your AVS:"
echo "   source .env && forge script scripts/DeployAVS.s.sol:DeployAVS --rpc-url \$RPC_URL --broadcast --verify"
echo ""
echo "3. Register validators:"
echo "   forge script scripts/DeployAVS.s.sol:AVSDemo --rpc-url \$RPC_URL"
echo ""
echo "🔒 Security Reminders:"
echo "- Never commit .env file to version control"
echo "- Use separate keys for testnet and mainnet"
echo "- Keep your private keys secure"
echo ""
echo "✅ Environment setup complete!" 