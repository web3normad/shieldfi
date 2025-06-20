
const CONFIG = require("../config/constants");

class AnalyticsEngine {
  constructor(providerManager) {
    this.providerManager = providerManager;
    
  
    this.gasAnalytics = {
      recentGasPrices: [],
      avgGasPrice: 0,
      maxGasPrice: 0,
      minGasPrice: 0,
      maxSize: CONFIG.ANALYTICS.GAS_PRICE_HISTORY_SIZE
    };
    
    
    this.pendingTransactions = new Map();
    this.suspiciousPatterns = new Map();
 
    this.stats = {
      totalTransactionsAnalyzed: 0,
      sandwichAttacksDetected: 0,
      arbitrageDetected: 0,
      flashLoansDetected: 0,
      liquidationsDetected: 0,
      alertsTriggered: 0,
      averageBlockProcessingTime: 0,
      uptime: Date.now()
    };
    
    this.startGasAnalytics();
    this.startPerformanceMonitoring();
  }

  // ================= GAS ANALYTICS =================
  startGasAnalytics() {
    this.gasAnalyticsInterval = setInterval(async () => {
      try {
        const feeData = await this.providerManager.safeProviderCall('getFeeData');
        this.updateGasAnalytics(feeData);
      } catch (error) {
        console.error("Gas analytics error:", error.message);
      }
    }, CONFIG.ANALYTICS.GAS_ANALYTICS_INTERVAL);
  }

  updateGasAnalytics(feeData) {
    if (!feeData || !feeData.gasPrice) return;
    
    const gasPrice = Number(feeData.gasPrice);
    if (gasPrice <= 0) return;
    
    this.gasAnalytics.recentGasPrices.push(gasPrice);
    
    
    if (this.gasAnalytics.recentGasPrices.length > this.gasAnalytics.maxSize) {
      this.gasAnalytics.recentGasPrices.shift();
    }
    
  
    this.gasAnalytics.avgGasPrice = this.calculateAverage(this.gasAnalytics.recentGasPrices);
    this.gasAnalytics.maxGasPrice = Math.max(...this.gasAnalytics.recentGasPrices);
    this.gasAnalytics.minGasPrice = Math.min(...this.gasAnalytics.recentGasPrices);
  }

  detectGasAnomaly(gasPrice) {
    if (!gasPrice || this.gasAnalytics.avgGasPrice === 0) return false;
    const currentGas = Number(gasPrice);
    return currentGas > (this.gasAnalytics.avgGasPrice * CONFIG.THRESHOLDS.GAS_ANOMALY_MULTIPLIER);
  }

  getGasAnalytics() {
    return {
      ...this.gasAnalytics,
      gasPricePercentiles: this.calculatePercentiles(this.gasAnalytics.recentGasPrices),
      volatility: this.calculateVolatility(this.gasAnalytics.recentGasPrices)
    };
  }

  
  addPendingTransaction(tx) {
    if (!tx || !tx.hash) return;
    
    const gasPrice = tx.gasPrice || tx.maxFeePerGas;
    const flags = [];
    
    if (this.detectGasAnomaly(gasPrice)) {
      flags.push("HIGH_GAS");
    }
    
    if (tx.value && tx.value > CONFIG.THRESHOLDS.LARGE_SWAP) {
      flags.push("LARGE_VALUE");
    }
    
    this.pendingTransactions.set(tx.hash, {
      ...tx,
      timestamp: Date.now(),
      flags,
      analyzed: false
    });
    
    this.stats.totalTransactionsAnalyzed++;
    this.cleanupOldTransactions();
  }

  flagSuspiciousTransaction(tx, flag) {
    if (!tx || !tx.hash) return;
    
    if (!this.pendingTransactions.has(tx.hash)) {
      this.addPendingTransaction(tx);
    }
    
    const txData = this.pendingTransactions.get(tx.hash);
    if (!txData.flags.includes(flag)) {
      txData.flags.push(flag);
    }
  }

  cleanupOldTransactions() {
    const now = Date.now();
    const maxAge = CONFIG.ANALYTICS.TRANSACTION_MAX_AGE;
    
    for (const [hash, tx] of this.pendingTransactions.entries()) {
      if (now - tx.timestamp > maxAge) {
        this.pendingTransactions.delete(hash);
      }
    }
  }

  startPerformanceMonitoring() {
    this.performanceInterval = setInterval(() => {
      this.updatePerformanceMetrics();
    }, CONFIG.ANALYTICS.HEALTH_CHECK_INTERVAL);
  }

  updatePerformanceMetrics() {
    const now = Date.now();
    const uptime = now - this.stats.uptime;
    
    this.stats.uptime = uptime;
    this.stats.pendingTransactionsCount = this.pendingTransactions.size;
    this.stats.suspiciousPatternsCount = this.suspiciousPatterns.size;
  }

  recordBlockProcessingTime(startTime) {
    const processingTime = Date.now() - startTime;
    

    if (this.stats.averageBlockProcessingTime === 0) {
      this.stats.averageBlockProcessingTime = processingTime;
    } else {
      this.stats.averageBlockProcessingTime = 
        (this.stats.averageBlockProcessingTime * 0.9) + (processingTime * 0.1);
    }
    
    if (processingTime > CONFIG.ANALYTICS.BLOCK_ANALYSIS_MAX_TIME) {
      console.warn(`⏱️ Block analysis exceeded ${CONFIG.ANALYTICS.BLOCK_ANALYSIS_MAX_TIME}ms: ${processingTime}ms`);
    }
    
    return processingTime;
  }

  // ================= PATTERN ANALYSIS =================
  recordMEVPattern(type, data) {
    const patternKey = `${type}_${Date.now()}`;
    this.suspiciousPatterns.set(patternKey, {
      type,
      data,
      timestamp: Date.now()
    });
    
    // Update statistics
    switch (type) {
      case "SANDWICH_ATTACK":
        this.stats.sandwichAttacksDetected++;
        break;
      case "ARBITRAGE":
        this.stats.arbitrageDetected++;
        break;
      case "FLASH_LOAN_MEV":
        this.stats.flashLoansDetected++;
        break;
      case "LIQUIDATION_SANDWICH":
        this.stats.liquidationsDetected++;
        break;
    }
  }

  triggerAlert(type, data) {
    this.stats.alertsTriggered++;
    
    const alert = {
      type,
      timestamp: Date.now(),
      riskScore: data.riskScore,
      data
    };
    
    console.log(`🚨 MEV ALERT - ${type} (Risk: ${data.riskScore}/10)`);
    console.log(JSON.stringify(alert, null, 2));
    
    this.recordMEVPattern(type, data);
    
    return alert;
  }


  getStatistics() {
    const now = Date.now();
    const uptimeHours = (now - this.stats.uptime) / (1000 * 60 * 60);
    
    return {
      ...this.stats,
      uptimeHours: Math.round(uptimeHours * 100) / 100,
      transactionsPerHour: Math.round(this.stats.totalTransactionsAnalyzed / uptimeHours),
      alertsPerHour: Math.round(this.stats.alertsTriggered / uptimeHours),
      gasAnalytics: this.getGasAnalytics(),
      memoryUsage: this.getMemoryUsage()
    };
  }

  getMemoryUsage() {
    return {
      pendingTransactions: this.pendingTransactions.size,
      suspiciousPatterns: this.suspiciousPatterns.size,
      gasHistorySize: this.gasAnalytics.recentGasPrices.length
    };
  }

  generateReport() {
    const stats = this.getStatistics();
    const report = {
      timestamp: new Date().toISOString(),
      summary: {
        uptime: `${stats.uptimeHours} hours`,
        totalTransactions: stats.totalTransactionsAnalyzed,
        totalAlerts: stats.alertsTriggered,
        averageProcessingTime: `${Math.round(stats.averageBlockProcessingTime)}ms`
      },
      detections: {
        sandwichAttacks: stats.sandwichAttacksDetected,
        arbitrage: stats.arbitrageDetected,
        flashLoans: stats.flashLoansDetected,
        liquidations: stats.liquidationsDetected
      },
      performance: {
        transactionsPerHour: stats.transactionsPerHour,
        alertsPerHour: stats.alertsPerHour,
        memoryUsage: stats.memoryUsage
      },
      gasAnalytics: stats.gasAnalytics
    };
    
    return report;
  }


  calculateAverage(numbers) {
    if (!numbers || numbers.length === 0) return 0;
    return numbers.reduce((sum, num) => sum + num, 0) / numbers.length;
  }

  calculatePercentiles(numbers) {
    if (!numbers || numbers.length === 0) return {};
    
    const sorted = [...numbers].sort((a, b) => a - b);
    const len = sorted.length;
    
    return {
      p10: sorted[Math.floor(len * 0.1)],
      p25: sorted[Math.floor(len * 0.25)],
      p50: sorted[Math.floor(len * 0.5)],
      p75: sorted[Math.floor(len * 0.75)],
      p90: sorted[Math.floor(len * 0.9)],
      p95: sorted[Math.floor(len * 0.95)],
      p99: sorted[Math.floor(len * 0.99)]
    };
  }

  calculateVolatility(numbers) {
    if (!numbers || numbers.length < 2) return 0;
    
    const avg = this.calculateAverage(numbers);
    const squaredDiffs = numbers.map(num => Math.pow(num - avg, 2));
    const variance = this.calculateAverage(squaredDiffs);
    
    return Math.sqrt(variance);
  }

  cleanup() {
    if (this.gasAnalyticsInterval) {
      clearInterval(this.gasAnalyticsInterval);
    }
    
    if (this.performanceInterval) {
      clearInterval(this.performanceInterval);
    }
    
    this.pendingTransactions.clear();
    this.suspiciousPatterns.clear();
    this.gasAnalytics.recentGasPrices = [];
  }
}

module.exports = AnalyticsEngine;