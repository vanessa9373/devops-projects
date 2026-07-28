const express = require('express');
const healthRouter = require('./routes/health');
const widgetsRouter = require('./routes/widgets');
const versionRouter = require('./routes/version');

const app = express();
app.use(express.json());

app.use('/health', healthRouter);
app.use('/version', versionRouter);
app.use('/api/widgets', widgetsRouter);

app.use((req, res) => {
  res.status(404).json({ error: `Not found: ${req.method} ${req.path}` });
});

const PORT = process.env.PORT || 3000;

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`Server listening on port ${PORT}`);
  });
}

module.exports = app;
