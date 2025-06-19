const { DETECTION_PARAMS } = require('../config');

// Calculate risk score (1-10) with V4 optimizations
function calculateRiskScore(detectionResults) {
  const weights = {
    sandwich: 0.7,
    liquidation: 0.6,
    gasAnomaly: 0.4,
    largeSwap: 0.5,
    v4Specific: 0.8  // Higher weight for V4 patterns
  };
  
  let score = 0;
  
  // Weighted risk calculation
  if (detectionResults.sandwich) {
    score += detectionResults.sandwich * weights.sandwich;
  }
  
  if (detectionResults.liquidation) {
    score += detectionResults.liquidation * weights.liquidation;
  }
  
  score += detectionResults.gasAnomaly * weights.gasAnomaly;
  score += detectionResults.largeSwap * weights.largeSwap;
  score += detectionResults.v4Specific * weights.v4Specific;
  
  // Apply V4 risk multiplier
  if (detectionResults.isV4) {
    score *= 1.3;
  }
  
  // Normalize to 1-10 scale
  return Math.min(10, Math.max(1, Math.round(score * 10)));
}

module.exports = {
  calculateRiskScore
};