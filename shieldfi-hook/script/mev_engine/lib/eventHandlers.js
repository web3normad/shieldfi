class EventHandlers {
  constructor(engine) {
    this.engine = engine;
  }

  setupContractEvents() {
    this.engine.contract.on("LiquidationCall", async (...args) => {
      const event = args[args.length - 1];
      const riskScore = await this.engine.analyzeLiquidation(event);
      
      if (riskScore > 6) {
        this.engine.triggerMEVAlert("LIQUIDATION_SANDWICH", {
          event,
          riskScore
        });
      }
    });
  }

  setupProviderEvents() {
    this.engine.providerManager.provider.on("block", async (blockNumber) => {
      await this.engine.analyzeBlockForMEV(blockNumber);
    });
    
    this.engine.providerManager.provider.on("pending", (txHash) => {
      this.engine.mempoolQueue.push(txHash);
      if (!this.engine.isProcessingQueue) {
        this.engine.processMempoolQueue();
      }
    });
  }
}

module.exports = EventHandlers;