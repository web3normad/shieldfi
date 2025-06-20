require("dotenv").config();
const MEVDetectionEngine = require("./lib/MEVDetectionEngine");

const mevEngine = new MEVDetectionEngine();

console.log(" MEV Detection Engine Started");
console.log("Monitoring: Uniswap V2/V3/V4, Aave, Flash Loans");


setInterval(async () => {
  try {
    const block = await mevEngine.providerManager.safeCall('getBlockNumber');
    console.log(` Health: Block ${block} | Errors ${
      mevEngine.providerManager.errorCount
    }`);
  } catch (error) {
    console.error("Health check failed:", error);
  }
}, 30000);


process.on("SIGINT", () => {
  console.log("Shutting down...");
  mevEngine.gasAnalytics.stopMonitoring();
  process.exit();
});