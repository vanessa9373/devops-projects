const express = require('express');

const router = express.Router();

// In-memory store — this app exists to demonstrate the pipeline, not to be
// a real datastore. Swap for RDS/DynamoDB if this ever becomes a real service.
let widgets = [
  { id: 1, name: 'Sample Widget', inStock: true },
];
let nextId = 2;

router.get('/', (req, res) => {
  res.json(widgets);
});

router.get('/:id', (req, res) => {
  const widget = widgets.find((w) => w.id === Number(req.params.id));
  if (!widget) return res.status(404).json({ error: 'Widget not found' });
  return res.json(widget);
});

router.post('/', (req, res) => {
  const { name, inStock = true } = req.body;
  if (!name) return res.status(400).json({ error: 'name is required' });

  const widget = { id: nextId++, name, inStock };
  widgets.push(widget);
  return res.status(201).json(widget);
});

router.delete('/:id', (req, res) => {
  const before = widgets.length;
  widgets = widgets.filter((w) => w.id !== Number(req.params.id));
  if (widgets.length === before) return res.status(404).json({ error: 'Widget not found' });
  return res.status(204).send();
});

module.exports = router;
