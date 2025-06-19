const { DETECTION_PARAMS } = require('./config');
const { NATIVE_ETH } = DETECTION_PARAMS;

async function convertToETHValue(amount, tokenAddress, poolManager) {
  if (tokenAddress === NATIVE_ETH) {
    return amount;
  }
  

  return amount * 3000n;
}


function isNativeETH(address) {
  return address === NATIVE_ETH;
}


function getTransactionValue(tx) {
  return tx.value || 0n;
}

module.exports = {
  convertToETHValue,
  isNativeETH,
  getTransactionValue
};