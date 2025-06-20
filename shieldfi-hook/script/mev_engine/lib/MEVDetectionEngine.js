const ProviderManager = require("./providers");
const GasAnalytics = require("./gasAnalytics");
const DetectionPatterns = require("./detectionPatterns");
const EventHandlers = require("./eventHandlers");
const Utils = require("./utils");
const config = require("../config/config")
const {ethers}=require("ethers")
const ABI = require("../Abi/aava_abi")
class MEVDetectionEngine {
  constructor() {
    this.providerManager = new ProviderManager();
    this.gasAnalytics = new GasAnalytics(this.providerManager);
    this.detectionPatterns = new DetectionPatterns(this.providerManager);
    this.eventHandlers = new EventHandlers(this);
    
    this.contract = new ethers.Contract(
      process.env.AAVE_V3_LENDING_POOL_ADDRESS,
      ABI,
      this.providerManager.provider
    );
    
    this.pendingTransactions = new Map();
    this.mempoolQueue = [];
    this.isProcessingQueue = false;
    
    this.initialize();
  }

  initialize() {
    this.gasAnalytics.startMonitoring();
    this.eventHandlers.setupContractEvents();
    this.eventHandlers.setupProviderEvents();
  }

  async analyzeBlockForMEV(blockNumber) {
    const block = await this.providerManager.safeCall(
      'getBlock', 
      blockNumber, 
      true
    );
    
    if (!block?.transactions?.length) return;
    
    const patterns = [
      ...this.detectionPatterns.detectSandwichAttacks(block.transactions),
      ...this.detectionPatterns.detectArbitragePatterns(block.transactions),
      ...this.detectionPatterns.detectFlashLoanMEV(block.transactions)
    ];
    
    patterns.forEach(pattern => {
      if (pattern.riskScore > 7) this.triggerMEVAlert(pattern.type, pattern);
    });
  }

  async processMempoolQueue() {
    this.isProcessingQueue = true;
    const BATCH_SIZE = 5;
    
    while (this.mempoolQueue.length > 0) {
      const batch = this.mempoolQueue.splice(0, BATCH_SIZE);
      await Promise.all(batch.map(this.processTransaction.bind(this)));
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    
    this.isProcessingQueue = false;
  }

  async processTransaction(txHash) {
    try {
      const tx = await this.providerManager.safeCall('getTransaction', txHash);
      if (!tx) return;
      
      if (this.gasAnalytics.detectAnomaly(tx.gasPrice || tx.maxFeePerGas)) {
        this.flagSuspicious(tx, "HIGH_GAS");
      }
      
      this.pendingTransactions.set(tx.hash, {
        ...tx,
        timestamp: Date.now()
      });
      
      Utils.cleanupMap(this.pendingTransactions);
    } catch (error) {
      this.providerManager.handleError(error);
    }
  }

  triggerMEVAlert(type, data) {
    console.log(`🚨 MEV ALERT - ${type} (Risk: ${data.riskScore}/10)`);
    // Additional alert logic
  }
}

module.exports = MEVDetectionEngine;