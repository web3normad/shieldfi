const { DETECTION_PARAMS } = require('./config');

class MEVAlertSystem {
  constructor() {
    this.alerts = [];
  }
  
  triggerAlert(type, data) {
    const alert = {
      timestamp: Date.now(),
      type,
      data,
      severity: this.getSeverity(data.riskScore)
    };
    
    this.alerts.push(alert);
    
    
    console.log(`🚨 MEV ALERT: ${type} | Risk: ${data.riskScore}/10`);
    
    if (alert.severity === 'CRITICAL') {
      this.activateProtection(data.tx);
    }
  }
  
  getSeverity(riskScore) {
    if (riskScore >= 9) return 'CRITICAL';
    if (riskScore >= 7) return 'HIGH';
    if (riskScore >= 5) return 'MEDIUM';
    return 'LOW';
  }
  
  activateProtection(tx) {
    
    console.log(`🛡️ Activating protection for TX: ${tx.hash}`);
  }
}

module.exports = MEVAlertSystem;