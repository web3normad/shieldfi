const { detectGasAnomaly } = require('../analytics/gas-analyzer');
const { getTransactionValue } = require('../utils');

function detectLiquidationExploitation(liquidation, context) {
  const startGas = gasleft();
  
  let riskScore = 5; 

  if (detectGasAnomaly(liquidation.tx.gasPrice, context.avgGasPrice)) {
    riskScore += 3;
  }
  

  const value = getTransactionValue(liquidation.tx);
  if (value > context.avgLiquidationSize * 2n) {
    riskScore += 2;
  }

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

function detectV4LiquidationFeatures(liquidation) {

  return 2;
}

module.exports = {
  detectLiquidationExploitation
};