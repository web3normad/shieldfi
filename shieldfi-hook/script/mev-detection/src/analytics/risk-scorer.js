const { DETECTION_PARAMS } = require('../config');


function calculateRiskScore(detectionResults) {
  const weights = {
    sandwich: 0.7,
    liquidation: 0.6,
    gasAnomaly: 0.4,
    largeSwap: 0.5,
    v4Specific: 0.8  
  };
  
  let score = 0;

  if (detectionResults.sandwich) {
    score += detectionResults.sandwich * weights.sandwich;
  }
  
  if (detectionResults.liquidation) {
    score += detectionResults.liquidation * weights.liquidation;
  }
  
  score += detectionResults.gasAnomaly * weights.gasAnomaly;
  score += detectionResults.largeSwap * weights.largeSwap;
  score += detectionResults.v4Specific * weights.v4Specific;
  
  if (detectionResults.isV4) {
    score *= 1.3;
  }
 
  return Math.min(10, Math.max(1, Math.round(score * 10)));
}

module.exports = {
  calculateRiskScore
};