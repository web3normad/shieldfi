const { DETECTION_PARAMS } = require('../config');

// Gas anomaly detection optimized for V4
function detectGasAnomaly(txGasPrice, avgGasPrice) {
  if (!avgGasPrice || avgGasPrice === 0n) return false;
  
  const gasRatio = Number(txGasPrice) / Number(avgGasPrice);
  return gasRatio > DETECTION_PARAMS.GAS_ANOMALY_FACTOR;
}

// Gas usage tracker
function trackGasUsage(startGas, context) {
  const gasUsed = startGas - gasleft();
  context.totalGasUsed += gasUsed;
  context.checkCount++;
  
  if (gasUsed > DETECTION_PARAMS.MAX_GAS_PER_CHECK) {
    console.warn(`Gas limit exceeded: ${gasUsed}`);
  }
  
  return gasUsed;
}

module.exports = {
  detectGasAnomaly,
  trackGasUsage
};