const { detectGasAnomaly } = require('../analytics/gas-analyzer');
const { getTransactionValue } = require('../utils');

function detectLiquidationExploitation(liquidation, context) {
  const startGas = gasleft();
  
  let riskScore = 5; // Base risk
  
  // 1. Gas price anomaly
  if (detectGasAnomaly(liquidation.tx.gasPrice, context.avgGasPrice)) {
    riskScore += 3;
  }
  
  // 2. Value-based risk (using native ETH value)
  const value = getTransactionValue(liquidation.tx);
  if (value > context.avgLiquidationSize * 2n) {
    riskScore += 2;
  }
  
  // 3. V4-specific features
  if (liquidation.hookAddress) {
    riskScore += detectV4LiquidationFeatures(liquidation);
  }
  
  // Gas optimization
  const gasUsed = startGas - gasleft();
  if (gasUsed > DETECTION_PARAMS.MAX_GAS_PER_CHECK) {
    console.warn(`Liquidation detection gas exceeded: ${gasUsed}`);
  }
  
  return Math.min(10, riskScore);
}

// V4-specific liquidation detection
function detectV4LiquidationFeatures(liquidation) {
  // Placeholder for V4-specific logic
  return 2;
}

module.exports = {
  detectLiquidationExploitation
};