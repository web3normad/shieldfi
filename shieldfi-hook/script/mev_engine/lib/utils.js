const config = require("../config/config");

class Utils {
  static isFlashLoanTransaction(tx) {
    return tx.data && config.FLASH_LOAN_SIGNATURES.some(
      sig => tx.data.startsWith(sig)
    );
  }

  static cleanupMap(map, maxAge = 5 * 60 * 1000) {
    const now = Date.now();
    for (const [key, value] of map.entries()) {
      if (now - value.timestamp > maxAge) map.delete(key);
    }
  }

  static calculateArbitrageRisk(txs) {
    return txs.length * 2; 
  }
}

module.exports = Utils;