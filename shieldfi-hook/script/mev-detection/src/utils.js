const { DETECTION_PARAMS } = require('./config');
const { NATIVE_ETH } = DETECTION_PARAMS;

// Convert any token to ETH value using Uniswap V4 pools
async function convertToETHValue(amount, tokenAddress, poolManager) {
  if (tokenAddress === NATIVE_ETH) {
    return amount;
  }
  
  // In production: Use V4 pool to get conversion rate
  // Placeholder implementation
  return amount * 3000n; // Assuming ETH at $3000
}

// Check if address is native ETH
function isNativeETH(address) {
  return address === NATIVE_ETH;
}

// Handle native ETH in transactions
function getTransactionValue(tx) {
  return tx.value || 0n;
}

module.exports = {
  convertToETHValue,
  isNativeETH,
  getTransactionValue
};