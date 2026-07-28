const express = require('express');

const router = express.Router();

// GIT_SHA / BUILD_TIME are injected as Docker build args in CI so a running
// ECS task can be identified against the pipeline run that shipped it.
router.get('/', (req, res) => {
  res.status(200).json({
    gitSha: process.env.GIT_SHA || 'local',
    buildTime: process.env.BUILD_TIME || null,
  });
});

module.exports = router;
