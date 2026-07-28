const express = require('express');

const router = express.Router();

// Polled by the ALB target group health check and the container HEALTHCHECK.
// Must stay dependency-free (no DB calls) so it reflects process liveness only.
router.get('/', (req, res) => {
  res.status(200).json({ status: 'healthy', uptimeSeconds: process.uptime() });
});

module.exports = router;
