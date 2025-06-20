const { ethers } = require("ethers");
const { detectSandwichAttack } = require("../detection/sandwich");
const { detectLiquidationExploitation } = require("../detection/liquidation");
const { detectV4MEV } = require("./v4-patterns");
const { calculateRiskScore } = require("../analytics/risk-scorer");
const MEVAlertSystem = require("../alert-system");
const { DETECTION_PARAMS } = require("../config");
const { isNativeETH, convertToETHValue } = require("../utils");

class MEVDetectionEngine {
  constructor(provider) {
    this.provider = provider;
    this.alertSystem = new MEVAlertSystem();
    
    // State tracking
    this.avgGasPrice = 0n;
    this.gasPrices = [];
    this.maxGasPrices = 100;
    
    // Statistics
    this.blocksProcessed = 0;
    this.detections = 0;
    this.totalGasUsed = 0n;
    
    // Start background services
    this.startGasAnalytics();
  }
  
  // Initialize the detection engine
  async start() {
    console.log("🚀 Starting MEV Detection Engine");
    console.log(`🔄 Monitoring Uniswap V4 with native ETH support`);
    
    // Set up block listener
    this.provider.on("block", async (blockNumber) => {
      try {
        const block = await this.provider.getBlock(blockNumber, true);
        await this.analyzeBlock(block);
      } catch (error) {
        console.error(`Error processing block ${blockNumber}:`, error);
      }
    });
    
    console.log("✅ Engine started and listening for new blocks");
  }
  
  // Analyze a block for MEV opportunities
  async analyzeBlock(block) {
    const startTime = Date.now();
    this.blocksProcessed++;
    
    // Process transactions in parallel batches
    const batchSize = 5;
    for (let i = 0; i < block.transactions.length; i += batchSize) {
      const batch = block.transactions.slice(i, i + batchSize);
      await Promise.all(batch.map(tx => this.analyzeTransaction(tx, block)));
    }
    
    // Performance monitoring
    const processingTime = Date.now() - startTime;
    if (processingTime > DETECTION_PARAMS.MAX_DETECTION_TIME_MS) {
      console.warn(`⏱️ Block ${block.number} processing took ${processingTime}ms (over limit)`);
    }
    
    // Periodic stats logging
    if (this.blocksProcessed % 10 === 0) {
      this.logStatistics();
    }
  }
  
  // Analyze individual transaction
  async analyzeTransaction(tx, block) {
    // Skip contract creation transactions
    if (!tx.to) return;
    
    const detectionResults = {
      sandwich: 0,
      liquidation: 0,
      v4Specific: 0,
      gasAnomaly: 0,
      largeSwap: false,
      isV4: false
    };
    
    // Track gas usage
    const startGas = gasleft();
    
    try {
      // 1. Check if it's a V4 transaction
      detectionResults.isV4 = DETECTION_PARAMS.V4_HOOKS.includes(tx.to) || 
                            tx.to === DETECTION_PARAMS.V4_POOL_MANAGER;
      
      // 2. Convert value to ETH for analysis
      const valueInETH = isNativeETH(tx.to) ? 
        tx.value : 
        await convertToETHValue(tx.value, tx.to, this);
      
      // 3. Large swap detection (in ETH terms)
      detectionResults.largeSwap = valueInETH > DETECTION_PARAMS.LARGE_SWAP_THRESHOLD;
      
      // 4. Gas price anomaly detection
      detectionResults.gasAnomaly = detectGasAnomaly(tx.gasPrice, this.avgGasPrice) ? 1 : 0;
      
      // 5. Pattern-specific detection
      detectionResults.sandwich = await detectSandwichAttack(tx, {
        block,
        avgGasPrice: this.avgGasPrice,
        engine: this
      });
      
      detectionResults.liquidation = await detectLiquidationExploitation(tx, {
        block,
        avgGasPrice: this.avgGasPrice
      });
      
      // 6. V4-specific detection
      if (detectionResults.isV4) {
        detectionResults.v4Specific = detectV4MEV(tx, {
          block,
          avgGasPrice: this.avgGasPrice
        });
      }
      
      // Calculate overall risk score
      const riskScore = calculateRiskScore(detectionResults);
      
      // Trigger alert if high risk
      if (riskScore >= 7) {
        this.detections++;
        this.alertSystem.triggerAlert('MEV_DETECTED', {
          tx,
          riskScore,
          patterns: detectionResults,
          block: block.number
        });
      }
      
      // Gas usage tracking
      const gasUsed = startGas - gasleft();
      this.totalGasUsed += BigInt(gasUsed);
      
      if (gasUsed > DETECTION_PARAMS.MAX_GAS_PER_CHECK) {
        console.warn(`⚠️ Gas limit exceeded in TX ${tx.hash}: ${gasUsed} gas`);
      }
    } catch (error) {
      console.error(`Error analyzing TX ${tx.hash}:`, error);
    }
  }
  
  // Track gas prices over time
  startGasAnalytics() {
    setInterval(async () => {
      try {
        const feeData = await this.provider.getFeeData();
        const gasPrice = BigInt(feeData.gasPrice.toString());
        
        this.gasPrices.push(gasPrice);
        if (this.gasPrices.length > this.maxGasPrices) {
          this.gasPrices.shift();
        }
        
        // Calculate average gas price
        const sum = this.gasPrices.reduce((a, b) => a + b, 0n);
        this.avgGasPrice = sum / BigInt(this.gasPrices.length);
      } catch (error) {
        console.error('Gas analytics error:', error);
      }
    }, 15000); // Update every 15 seconds
  }
  
  // Log engine statistics
  logStatistics() {
    const avgGasPerTx = this.blocksProcessed > 0 ? 
      Number(this.totalGasUsed) / this.blocksProcessed : 0;
    
    console.log('\n📊 Engine Statistics:');
    console.log(`- Blocks processed: ${this.blocksProcessed}`);
    console.log(`- MEV detections: ${this.detections}`);
    console.log(`- Avg gas price: ${ethers.formatUnits(this.avgGasPrice, 'gwei')} gwei`);
    console.log(`- Avg gas per TX: ${avgGasPerTx.toFixed(0)}`);
    console.log(`- Detection rate: ${(this.detections / this.blocksProcessed * 100).toFixed(2)}%`);
  }
  
  // Connect to alert system
  onAlert(callback) {
    this.alertSystem.onAlert(callback);
  }
}

module.exports = MEVDetectionEngine;