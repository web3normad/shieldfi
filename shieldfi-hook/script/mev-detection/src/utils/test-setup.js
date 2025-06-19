
const { ethers } = require("ethers");

jest.useFakeTimers();

global.ethers = ethers;

BigInt.prototype.toJSON = function() {
  return this.toString();
};

const originalConsoleLog = console.log;
console.log = (...args) => {
  if (!process.env.CI) {
    originalConsoleLog(...args);
  }
};