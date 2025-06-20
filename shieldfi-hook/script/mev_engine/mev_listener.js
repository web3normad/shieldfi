

const { ethers } = require("ethers");
const ABI = require("../Abi/aava_abi");
require("dotenv").config();

class MEVDetectionEngine {
  constructor() {

    this.provider = this.createProviderWithFallback();
    
    this.contract = new ethers.Contract(
      process.env.AAVE_V3_LENDING_POOL_ADDRESS,
      ABI,
      this.provider
    );

    this.pendingTransactions = new Map();
    this.suspiciousPatterns = new Map();
    this.gasAnalytics = {
      recentGasPrices: [],
      avgGasPrice: 0,
      maxSize: 100
    };
    

    this.LARGE_SWAP_THRESHOLD = ethers.parseEther("50000"); 
    this.GAS_ANOMALY_MULTIPLIER = 2.0;
    this.SANDWICH_TIME_WINDOW = 5; 
    

    this.errorCount = 0;
    this.MAX_ERRORS = 10;
    this.requestQueue = [];
    this.isProcessingQueue = false;

    this.detectSandwichAttacks = this.detectSandwichAttacks.bind(this);
    this.detectArbitragePatterns = this.detectArbitragePatterns.bind(this);
    this.detectFlashLoanMEV = this.detectFlashLoanMEV.bind(this);
    this.filterDEXTransactions = this.filterDEXTransactions.bind(this);
    
    this.setupEventListeners();
    this.startMempoolMonitoring();
    this.startGasAnalytics();
  }
  createProviderWithFallback() {
    try {
  
      return new ethers.WebSocketProvider(process.env.INFURA_URL_WSS);
    } catch (error) {
      console.warn("WebSocket failed, falling back to HTTP");
      return new ethers.JsonRpcProvider(process.env.INFURA_URL_HTTP);
    }
  }

  async rotateProvider() {
    console.log("🔄 Rotating provider due to errors...");
    try {
      if (this.provider) {
        this.provider.removeAllListeners();
        if (this.provider.destroy) await this.provider.destroy();
      }
      
   
      this.provider = process.env.BACKUP_PROVIDER_URL ?
        new ethers.WebSocketProvider(process.env.BACKUP_PROVIDER_URL) :
        new ethers.JsonRpcProvider(process.env.INFURA_URL_HTTP);
  
      this.detectSandwichAttacks = this.detectSandwichAttacks.bind(this);
      this.detectArbitragePatterns = this.detectArbitragePatterns.bind(this);
      this.detectFlashLoanMEV = this.detectFlashLoanMEV.bind(this);
      this.filterDEXTransactions = this.filterDEXTransactions.bind(this);
      
      this.setupEventListeners();
      this.errorCount = 0;
      console.log("✅ Provider rotation successful");
    } catch (e) {
      console.error("Provider rotation failed:", e);
    }
  }

  async safeProviderCall(method, ...args) {
    const MAX_RETRIES = 2;
    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
      try {
        return await this.provider[method](...args);
      } catch (error) {
        if (attempt === MAX_RETRIES) throw error;
        console.warn(`Retrying ${method} (attempt ${attempt+1})`);
        await new Promise(resolve => setTimeout(resolve, 1000 * (attempt + 1)));
      }
    }
  }


  setupEventListeners() {

    this.contract.on("LiquidationCall", async (...args) => {
      try {
        const event = args[args.length - 1];
        const riskScore = await this.analyzeLiquidation(event);
        
        if (riskScore > 6) {
          this.triggerMEVAlert("LIQUIDATION_SANDWICH", {
            event,
            riskScore,
            timestamp: Date.now()
          });
        }
        
        console.log(`⚡ Liquidation Detected - Risk Score: ${riskScore}/10`);
      } catch (error) {
        this.handleError("Liquidation processing", error);
      }
    });

    // Block monitoring with error handling
    this.provider.on("block", async (blockNumber) => {
      try {
        await this.analyzeBlockForMEV(blockNumber);
      } catch (error) {
        this.handleError(`Block ${blockNumber} analysis`, error);
      }
    });
  }

  async startMempoolMonitoring() {
    this.provider.on("pending", async (txHash) => {
      try {
        // Add to queue instead of processing immediately
        this.requestQueue.push(txHash);
        if (!this.isProcessingQueue) {
          this.processQueue();
        }
      } catch (error) {
        this.handleError("Mempool monitoring", error);
      }
    });
  }

  async processQueue() {
    if (this.isProcessingQueue || this.requestQueue.length === 0) return;
    
    this.isProcessingQueue = true;
    const BATCH_SIZE = 5;
    
    while (this.requestQueue.length > 0) {
      const batch = this.requestQueue.splice(0, BATCH_SIZE);
      
      try {
        await Promise.all(batch.map(async txHash => {
          try {
            const tx = await this.safeProviderCall('getTransaction', txHash);
            if (tx) await this.analyzePendingTransaction(tx);
          } catch (error) {
            // Skip tx if not available
          }
        }));
      } catch (error) {
        this.handleError("Transaction batch processing", error);
      }
      
      // Add delay between batches
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    
    this.isProcessingQueue = false;
  }

  async analyzePendingTransaction(tx) {
    if (!tx) return;  
    
    const gasPrice = tx.gasPrice || tx.maxFeePerGas;
    
    if (gasPrice && this.detectGasAnomaly(gasPrice)) {
      this.flagSuspiciousTransaction(tx, "HIGH_GAS");
    }
   
    if (tx.value && tx.value > this.LARGE_SWAP_THRESHOLD) {
      this.flagSuspiciousTransaction(tx, "LARGE_SWAP");
    }
    
   
    this.pendingTransactions.set(tx.hash, {
      ...tx,
      timestamp: Date.now(),
      flags: []
    });
    

    this.cleanupOldTransactions();
  }

  startGasAnalytics() {
    this.gasAnalyticsInterval = setInterval(async () => {
      if (this.errorCount > this.MAX_ERRORS) {
        console.error("⚠️ Critical error threshold reached. Pausing gas analytics.");
        return;
      }
      
      try {
     
        const feeData = await this.safeProviderCall('getFeeData');
        const gasPrice = feeData.gasPrice ? Number(feeData.gasPrice) : 0;
        
        if (gasPrice > 0) {
          this.gasAnalytics.recentGasPrices.push(gasPrice);
          
          if (this.gasAnalytics.recentGasPrices.length > this.gasAnalytics.maxSize) {
            this.gasAnalytics.recentGasPrices.shift();
          }
          
          this.gasAnalytics.avgGasPrice = 
            this.gasAnalytics.recentGasPrices.reduce((a, b) => a + b, 0) / 
            this.gasAnalytics.recentGasPrices.length;
        }
      } catch (error) {
        this.handleError("Gas analytics", error);
      }
    }, 15000); 
  }


  handleError(context, error) {
    this.errorCount++;
    console.error(`[${context}] Error (${this.errorCount}/${this.MAX_ERRORS}):`, error.message || error);
    
    if (this.errorCount > this.MAX_ERRORS) {
      console.error("🚨 Critical error threshold reached. Rotating provider...");
      this.rotateProvider();
    }
  }

  async analyzeBlockForMEV(blockNumber) {
    const startTime = Date.now();
    
    try {
      // Use safe provider call with retries
      const block = await this.safeProviderCall('getBlock', blockNumber, true);
      if (!block || !block.transactions || !block.transactions.length) return;

      // Sandwich attack detection
      const sandwichPatterns = this.detectSandwichAttacks(block.transactions);
      
      // Arbitrage detection
      const arbitragePatterns = this.detectArbitragePatterns(block.transactions);
      
      // Flash loan analysis
      const flashLoanPatterns = this.detectFlashLoanMEV(block.transactions);
      
      // Process all detected patterns
      [...sandwichPatterns, ...arbitragePatterns, ...flashLoanPatterns]
        .forEach(pattern => {
          if (pattern.riskScore > 7) {
            this.triggerMEVAlert(pattern.type, pattern);
          }
        });
        
    } catch (error) {
      this.handleError(`Block ${blockNumber} analysis`, error);
    }
    
    // Ensure gas efficiency
    const processingTime = Date.now() - startTime;
    if (processingTime > 200) {
      console.warn(`⏱️ Block analysis exceeded 200ms: ${processingTime}ms`);
    }
  }

  detectSandwichAttacks(transactions) {
    const patterns = [];
    if (!transactions || !transactions.length) return patterns;
    
    const dexInteractions = this.filterDEXTransactions(transactions);
    if (dexInteractions.length < 3) return patterns;
    
    for (let i = 0; i < dexInteractions.length - 2; i++) {
      const tx1 = dexInteractions[i];
      const tx2 = dexInteractions[i + 1]; // Victim transaction
      const tx3 = dexInteractions[i + 2];
      
      if (!tx1 || !tx2 || !tx3) continue;
      
      // Check if tx1 and tx3 are from same address (attacker)
      if (tx1.from === tx3.from && tx1.from !== tx2.from) {
        const pattern = this.analyzeSandwichPattern(tx1, tx2, tx3);
        if (pattern.riskScore > 5) {
          patterns.push({
            type: "SANDWICH_ATTACK",
            transactions: [tx1, tx2, tx3],
            riskScore: pattern.riskScore,
            profitEstimate: pattern.profitEstimate
          });
        }
      }
    }
    
    return patterns;
  }

  analyzeSandwichPattern(frontrun, victim, backrun) {
    let riskScore = 0;
    let profitEstimate = 0;
    
    if (!victim || !frontrun || !backrun) return { riskScore, profitEstimate };
    
    // Gas price analysis
    const frontrunGas = frontrun.gasPrice || frontrun.maxFeePerGas;
    const victimGas = victim.gasPrice || victim.maxFeePerGas;
    const backrunGas = backrun.gasPrice || backrun.maxFeePerGas;
    
    if (victimGas && frontrunGas > victimGas * 1.1) riskScore += 3;
    if (victimGas && backrunGas < victimGas * 0.9) riskScore += 2;
    
    // Value analysis
    if (victim.value > this.LARGE_SWAP_THRESHOLD) riskScore += 3;
    
    // Timing analysis (consecutive transactions)
    riskScore += 2;
    
    return { riskScore, profitEstimate };
  }

  detectArbitragePatterns(transactions) {
    const patterns = [];
    if (!transactions || !transactions.length) return patterns;
    
    const dexTxs = this.filterDEXTransactions(transactions);
    if (!dexTxs.length) return patterns;
    
    // Group by sender
    const txBySender = {};
    dexTxs.forEach(tx => {
      if (!tx || !tx.from) return;
      if (!txBySender[tx.from]) txBySender[tx.from] = [];
      txBySender[tx.from].push(tx);
    });
    
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

  detectFlashLoanMEV(transactions) {
    const patterns = [];
    if (!transactions || !transactions.length) return patterns;
    
    transactions.forEach(tx => {
      if (!tx) return;
      
      // Look for flash loan signatures in transaction data
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

  async analyzeLiquidation(event) {
    let riskScore = 5; 
    
    try {

      const block = await this.safeProviderCall('getBlock', event.blockNumber);
      if (!block || !block.transactions) return riskScore;
      
      const txIndex = block.transactions.indexOf(event.transactionHash);
      if (txIndex === -1) return riskScore;
      
  
      if (txIndex > 0 && txIndex < block.transactions.length - 1) {
        const [prevTx, nextTx] = await Promise.all([
          this.safeProviderCall('getTransaction', block.transactions[txIndex - 1]),
          this.safeProviderCall('getTransaction', block.transactions[txIndex + 1])
        ]);
        
        if (prevTx && nextTx && prevTx.from === nextTx.from) {
          riskScore += 3; 
        }
      }
  
      const tx = await this.safeProviderCall('getTransaction', event.transactionHash);
      if (tx) {
        const gasPrice = tx.gasPrice || tx.maxFeePerGas;
        if (gasPrice && this.detectGasAnomaly(gasPrice)) {
          riskScore += 2;
        }
      }
      
    } catch (error) {
      this.handleError("Liquidation analysis", error);
    }
    
    return Math.min(riskScore, 10);
  }

  detectGasAnomaly(gasPrice) {
    if (!gasPrice || this.gasAnalytics.avgGasPrice === 0) return false;
    const currentGas = Number(gasPrice);
    return currentGas > (this.gasAnalytics.avgGasPrice * this.GAS_ANOMALY_MULTIPLIER);
  }

  filterDEXTransactions(transactions) {
    if (!transactions || !transactions.length) return [];
    

    const dexAddresses = [
      "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
      "0xE592427A0AEce92De3Edee1F18E0157C05861564",
   
    ];
    
    return transactions.filter(tx => 
      tx && tx.to && dexAddresses.includes(tx.to.toLowerCase())
    );
  }

  calculateArbitrageRisk(transactions) {
    if (!transactions || !transactions.length) return 0;

    let risk = 0;
    if (transactions.length >= 2) risk += 4;
    if (transactions.length >= 3) risk += 2;
    return risk;
  }

  isFlashLoanTransaction(tx) {
    if (!tx || !tx.data) return false;
    

    const flashLoanSigs = [
      "0x5cffe9de",
      "0xab9c4b5d",
    ];
    
    return flashLoanSigs.some(sig => tx.data.startsWith(sig));
  }

  analyzeFlashLoanRisk(tx) {
 
    return 6;
  }

  flagSuspiciousTransaction(tx, flag) {
    if (!tx || !tx.hash) return;
    
    if (!this.pendingTransactions.has(tx.hash)) {
      this.pendingTransactions.set(tx.hash, { ...tx, flags: [] });
    }
    this.pendingTransactions.get(tx.hash).flags.push(flag);
  }

  cleanupOldTransactions() {
    const now = Date.now();
    const maxAge = 5 * 60 * 1000; // 5 minutes
    
    for (const [hash, tx] of this.pendingTransactions.entries()) {
      if (now - tx.timestamp > maxAge) {
        this.pendingTransactions.delete(hash);
      }
    }
  }

  triggerMEVAlert(type, data) {
    const alert = {
      type,
      timestamp: Date.now(),
      riskScore: data.riskScore,
      data
    };
    
    console.log(`🚨 MEV ALERT - ${type} (Risk: ${data.riskScore}/10)`);
    console.log(JSON.stringify(alert, null, 2));
    
   
    this.sendToAlertSystem(alert);
  }

  sendToAlertSystem(alert) {
  }
}

const mevEngine = new MEVDetectionEngine();

console.log("🔍 Advanced MEV Detection Engine Started");
console.log("📊 Monitoring: Sandwich Attacks, Arbitrage, Flash Loans, Liquidations");

setInterval(async () => {
  try {
    const blockNumber = await mevEngine.safeProviderCall('getBlockNumber');
    const pendingCount = mevEngine.pendingTransactions.size;
    console.log(`💓 Health: Block ${blockNumber} | Pending ${pendingCount} | Errors ${mevEngine.errorCount}`);
  } catch (error) {
    console.error("Health check failed:", error.message);
  }
}, 30000);