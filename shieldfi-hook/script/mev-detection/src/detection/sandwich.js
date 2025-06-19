const { DETECTION_PARAMS } = require('../config');
const { isNativeETH, getTransactionValue } = require('../utils');
const { detectGasAnomaly } = require('../analytics/gas-analyzer');

// Detect sandwich attacks optimized for V4 native ETH
function detectSandwichAttack(tx, context) {
  const startGas = gasleft();
  
  // 1. Check if V4 transaction
  const isV4Tx = DETECTION_PARAMS.V4_HOOKS.includes(tx.to) || 
                tx.to === DETECTION_PARAMS.V4_POOL_MANAGER;
  
  // 2. Extract value (handles native ETH)
  const value = getTransactionValue(tx);
  const valueInETH = isNativeETH(tx.tokenAddress) ? 
    value : 
    convertToETHValue(value, tx.tokenAddress, context.poolManager);
  
  // 3. Large swap detection (in ETH terms)
  const isLargeSwap = valueInETH > DETECTION_PARAMS.LARGE_SWAP_THRESHOLD;
  
  // 4. Gas price anomaly
  const gasAnomaly = detectGasAnomaly(tx.gasPrice, context.avgGasPrice);
  
  // 5. V4-specific features
  let v4Risk = 0;
  if (isV4Tx) {
    v4Risk = detectV4SandwichFeatures(tx, context);
  }
  
  // Risk scoring
  let riskScore = 0;
  if (isLargeSwap) riskScore += 4;
  if (gasAnomaly) riskScore += 3;
  riskScore += v4Risk;
  
  // Gas optimization check
  const gasUsed = startGas - gasleft();
  if (gasUsed > DETECTION_PARAMS.MAX_GAS_PER_CHECK) {
    console.warn(`Sandwich detection gas exceeded: ${gasUsed}`);
  }
  
  return Math.min(10, riskScore);
}

// V4-specific sandwich detection
function detectV4SandwichFeatures(tx, context) {
  let risk = 0;
  
  // 1. Detect JIT liquidity
  if (tx.functionName === 'modifyPosition' && getTransactionValue(tx) > 0) {
    risk += 3;
  }
  
  // 2. Hook manipulation detection
  if (tx.hookData && tx.hookData.length > 0) {
    risk += 2;
  }
  
  return risk;
}

module.exports = {
  detectSandwichAttack
};