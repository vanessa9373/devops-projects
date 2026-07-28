const request = require('supertest');
const app = require('../src/index');

describe('Widgets API', () => {
  it('lists widgets, seeded with one sample item', async () => {
    const res = await request(app).get('/api/widgets');
    expect(res.status).toBe(200);
    expect(res.body.length).toBeGreaterThanOrEqual(1);
  });

  it('creates a widget then fetches it by id', async () => {
    const create = await request(app).post('/api/widgets').send({ name: 'New Widget' });
    expect(create.status).toBe(201);
    expect(create.body.name).toBe('New Widget');

    const get = await request(app).get(`/api/widgets/${create.body.id}`);
    expect(get.status).toBe(200);
    expect(get.body.name).toBe('New Widget');
  });

  it('rejects widget creation without a name', async () => {
    const res = await request(app).post('/api/widgets').send({});
    expect(res.status).toBe(400);
  });

  it('returns 404 for a widget that does not exist', async () => {
    const res = await request(app).get('/api/widgets/999999');
    expect(res.status).toBe(404);
  });

  it('deletes a widget', async () => {
    const create = await request(app).post('/api/widgets').send({ name: 'Temp' });
    const del = await request(app).delete(`/api/widgets/${create.body.id}`);
    expect(del.status).toBe(204);

    const get = await request(app).get(`/api/widgets/${create.body.id}`);
    expect(get.status).toBe(404);
  });
});
