const { ethers } = require("ethers");
const MEVDetectionEngine= require("./core/engine")
const { DETECTION_PARAMS } = require('./config');
require("dotenv").config()

console.log("ENV", process.env.INFURA_URL_WSS)
const provider = new ethers.WebSocketProvider(process.env.INFURA_URL_WSS);
console.log("i am the provider", provider)
console.log(MEVDetectionEngine)
const mevEngine = new MEVDetectionEngine(provider);

mevEngine.start();


provider.on('block', async (blockNumber) => {
  const start = Date.now();
  const block = await provider.getBlock(blockNumber, true);
  
  await mevEngine.analyzeBlock(block);
  
  const latency = Date.now() - start;
  if (latency > DETECTION_PARAMS.MAX_DETECTION_TIME_MS) {
    console.warn(`Block ${blockNumber} processing latency: ${latency}ms`);
  }
});

console.log('🛡️ ShieldFi MEV Detection Engine Started');
console.log(`🔍 Monitoring Uniswap V4 with native ETH support`);

console.log('⚙️ Config:', {
  V4_HOOKS: DETECTION_PARAMS.V4_HOOKS,
  V4_POOL_MANAGER: DETECTION_PARAMS.V4_POOL_MANAGER,
  MAX_DETECTION_TIME_MS: DETECTION_PARAMS.MAX_DETECTION_TIME_MS,
  LARGE_SWAP_THRESHOLD: DETECTION_PARAMS.LARGE_SWAP_THRESHOLD
});