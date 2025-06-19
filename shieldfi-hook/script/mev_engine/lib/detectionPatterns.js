
const config = require("../config/config");
const { ethers } = require("ethers");

class DetectionPatterns {
  constructor(providerManager) {
    this.providerManager = providerManager;
  }

  detectSandwichAttacks(transactions) {
    const patterns = [];
    if (!transactions || !transactions.length) return patterns;
    
    const dexTxs = this.filterDEXTransactions(transactions);
    if (dexTxs.length < 3) return patterns;
    
    for (let i = 0; i < dexTxs.length - 2; i++) {
      const tx1 = dexTxs[i];
      const tx2 = dexTxs[i + 1];
      const tx3 = dexTxs[i + 2];
      
      if (tx1.from === tx3.from && tx1.from !== tx2.from) {
        const riskScore = this.analyzeSandwichPattern(tx1, tx2, tx3);
        if (riskScore > 5) {
          patterns.push({
            type: "SANDWICH_ATTACK",
            transactions: [tx1, tx2, tx3],
            riskScore
          });
        }
      }
    }
    return patterns;
  }

  analyzeSandwichPattern(frontrun, victim, backrun) {
    let riskScore = 0;
    
    // Gas analysis
    const victimGas = victim.gasPrice || victim.maxFeePerGas;
    if (victimGas) {
      const frontrunGas = frontrun.gasPrice || frontrun.maxFeePerGas;
      const backrunGas = backrun.gasPrice || backrun.maxFeePerGas;
      
      if (frontrunGas > victimGas * 1.1) riskScore += 3;
      if (backrunGas < victimGas * 0.9) riskScore += 2;
    }
    
    // Value analysis
    if (victim.value > config.THRESHOLDS.LARGE_SWAP) riskScore += 3;
    
    // Consecutive transactions
    riskScore += 2;
    
    return riskScore;
  }

  // ================= ARBITRAGE DETECTION =================
  detectArbitragePatterns(transactions) {
    const patterns = [];
    if (!transactions || !transactions.length) return patterns;
    
    const dexTxs = this.filterDEXTransactions(transactions);
    if (!dexTxs.length) return patterns;
    
    // Group by sender
    const txBySender = {};
    dexTxs.forEach(tx => {
      if (!txBySender[tx.from]) txBySender[tx.from] = [];
      txBySender[tx.from].push(tx);
    });
    
    // Analyze sender groups
    Object.entries(txBySender).forEach(([sender, txs]) => {
      if (txs.length >= 2) {
        const riskScore = this.calculateArbitrageRisk(txs);
        if (riskScore > 6) {
          patterns.push({
            type: "ARBITRAGE",
            transactions: txs,
            riskScore,
            sender
          });
        }
      }
    });
    
    return patterns;
  }

  calculateArbitrageRisk(transactions) {
    let risk = 0;
    
    // Multi-DEX interactions
    const dexCount = new Set(
      transactions.map(tx => tx.to.toLowerCase())
    ).size;
    
    if (dexCount >= 2) risk += 4;
    if (transactions.length >= 3) risk += 2;
    
    return risk;
  }


  detectFlashLoanMEV(transactions) {
    const patterns = [];
    if (!transactions || !transactions.length) return patterns;
    
    transactions.forEach(tx => {
      if (this.isFlashLoanTransaction(tx)) {
        const riskScore = this.analyzeFlashLoanRisk(tx);
        if (riskScore > 5) {
          patterns.push({
            type: "FLASH_LOAN_MEV",
            transaction: tx,
            riskScore
          });
        }
      }
    });
    
    return patterns;
  }

  isFlashLoanTransaction(tx) {
    return tx.data && config.FLASH_LOAN_SIGNATURES.some(
      sig => tx.data.startsWith(sig)
    );
  }

  analyzeFlashLoanRisk(tx) {
    let riskScore = 6; 
   
    if (tx.value > config.THRESHOLDS.LARGE_SWAP) riskScore += 2;
    
    return riskScore;
  }


  filterDEXTransactions(transactions) {
    if (!transactions || !transactions.length) return [];
    
    return transactions.filter(tx => 
      tx && tx.to && Object.values(config.DEX_ADDRESSES)
        .map(a => a.toLowerCase())
        .includes(tx.to.toLowerCase())
    );
  }
}

module.exports = DetectionPatterns;