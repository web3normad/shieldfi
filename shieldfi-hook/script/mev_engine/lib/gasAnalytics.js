class GasAnalytics {
  constructor(providerManager) {
    this.providerManager = providerManager;
    this.recentGasPrices = [];
    this.avgGasPrice = 0;
    this.maxSize = 100;
  }

  startMonitoring(interval = 15000) {
    this.intervalId = setInterval(async () => {
      try {
        const feeData = await this.providerManager.safeCall('getFeeData');
        const gasPrice = feeData.gasPrice ? Number(feeData.gasPrice) : 0;
        
        if (gasPrice > 0) {
          this.recentGasPrices.push(gasPrice);
          if (this.recentGasPrices.length > this.maxSize) {
            this.recentGasPrices.shift();
          }
          
          this.avgGasPrice = 
            this.recentGasPrices.reduce((a, b) => a + b, 0) / 
            this.recentGasPrices.length;
        }
      } catch (error) {
        this.providerManager.handleError(error);
      }
    }, interval);
  }

  detectAnomaly(gasPrice, multiplier = 2.0) {
    if (!gasPrice || this.avgGasPrice === 0) return false;
    return Number(gasPrice) > (this.avgGasPrice * multiplier);
  }

  stopMonitoring() {
    if (this.intervalId) clearInterval(this.intervalId);
  }
}

module.exports = GasAnalytics;