const { ethers } = require("ethers");

class ProviderManager {
  constructor() {
    this.provider = this.createProvider();
    this.errorCount = 0;
    this.MAX_ERRORS = 10;
  }

  createProvider() {
    try {
      return new ethers.WebSocketProvider(process.env.INFURA_URL_WSS);
    } catch (error) {
      console.warn("WebSocket failed, falling back to HTTP");
      return new ethers.JsonRpcProvider(process.env.INFURA_URL_HTTP);
    }
  }

  async rotateProvider() {
    console.log("🔄 Rotating provider...");
    try {
      if (this.provider.destroy) await this.provider.destroy();
      
      this.provider = process.env.BACKUP_PROVIDER_URL ?
        new ethers.WebSocketProvider(process.env.BACKUP_PROVIDER_URL) :
        new ethers.JsonRpcProvider(process.env.INFURA_URL_HTTP);
      
      this.errorCount = 0;
      return this.provider;
    } catch (e) {
      console.error("Provider rotation failed:", e);
      throw e;
    }
  }

  async safeCall(method, ...args) {
    const MAX_RETRIES = 2;
    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
      try {
        return await this.provider[method](...args);
      } catch (error) {
        if (attempt === MAX_RETRIES) throw error;
        await new Promise(resolve => setTimeout(resolve, 1000 * (attempt + 1)));
      }
    }
  }

  handleError(error) {
    this.errorCount++;
    if (this.errorCount > this.MAX_ERRORS) {
      this.rotateProvider();
    }
    return error;
  }
}

module.exports = ProviderManager;