const { DETECTION_PARAMS } = require('../config');
const { isNativeETH, getTransactionValue } = require('../utils');
const { detectGasAnomaly } = require('../analytics/gas-analyzer');

function detectSandwichAttack(tx, context) {
  const startGas = gasleft();
  
 
  const isV4Tx = DETECTION_PARAMS.V4_HOOKS.includes(tx.to) || 
                tx.to === DETECTION_PARAMS.V4_POOL_MANAGER;
 
  const value = getTransactionValue(tx);
  const valueInETH = isNativeETH(tx.tokenAddress) ? 
    value : 
    convertToETHValue(value, tx.tokenAddress, context.poolManager);
  
  const isLargeSwap = valueInETH > DETECTION_PARAMS.LARGE_SWAP_THRESHOLD;
  
  const gasAnomaly = detectGasAnomaly(tx.gasPrice, context.avgGasPrice);
  
  let v4Risk = 0;
  if (isV4Tx) {
    v4Risk = detectV4SandwichFeatures(tx, context);
  }
  
  let riskScore = 0;
  if (isLargeSwap) riskScore += 4;
  if (gasAnomaly) riskScore += 3;
  riskScore += v4Risk;

  const gasUsed = startGas - gasleft();
  if (gasUsed > DETECTION_PARAMS.MAX_GAS_PER_CHECK) {
    console.warn(`Sandwich detection gas exceeded: ${gasUsed}`);
  }
  
  return Math.min(10, riskScore);
}


function detectV4SandwichFeatures(tx, context) {
  let risk = 0;
  
  if (tx.functionName === 'modifyPosition' && getTransactionValue(tx) > 0) {
    risk += 3;
  }
 
  if (tx.hookData && tx.hookData.length > 0) {
    risk += 2;
  }
  
  return risk;
}

module.exports = {
  detectSandwichAttack
};