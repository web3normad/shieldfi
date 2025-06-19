const { DETECTION_PARAMS } = require('../config');
const { isNativeETH } = require('../utils');

// V4-specific MEV patterns
function detectV4MEV(tx, context) {
  // 1. Native ETH manipulation
  if (isNativeETH(tx.tokenAddress) && tx.value > DETECTION_PARAMS.LARGE_SWAP_THRESHOLD) {
    return 8;
  }
  
  // 2. Hook exploitation
  if (tx.hookAddress && tx.gasLimit > 150000) {
    return 7;
  }
  
  // 3. JIT liquidity attacks
  if (isJitAttack(tx, context)) {
    return 9;
  }
  
  return 0;
}

function isJitAttack(tx, context) {
  return (
    tx.functionName === 'modifyPosition' &&
    tx.blockNumber === context.currentBlock &&
    tx.gasPrice > context.avgGasPrice * 2n
  );
}

module.exports = {
  detectV4MEV
};