import { test, type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { cacheBust, cacheGet, cacheSet, cacheRemember } from '../src/lib/cache';
import { prisma } from '../src/lib/prisma';
import { getConfig, bustConfigCache } from '../src/services/config';
import { getMaintenance, bustMaintenanceCache } from '../src/services/maintenance';
import { activeRestrictions, bustRestrictions } from '../src/services/restrictions';

// Prisma delegates are proxies; Node's descriptor-based mock.method cannot
// discover their dynamically provided methods.
function mockQuery(t: TestContext, delegate: any, method: string, replacement: (...args: any[]) => any) {
  const original = delegate[method];
  delegate[method] = replacement;
  t.after(() => { delegate[method] = original; });
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}

test('100 simultaneous cache misses execute one load', async () => {
  let loads = 0;
  const wait = deferred<number>();
  const requests = Array.from({ length: 100 }, () => cacheRemember('test:burst', 1000, () => {
    loads++; return wait.promise;
  }));
  await Promise.resolve();
  assert.equal(loads, 1);
  wait.resolve(42);
  assert.deepEqual(await Promise.all(requests), Array(100).fill(42));
  assert.equal(cacheGet('test:burst'), 42);
});

test('invalidating an in-flight load prevents stale repopulation', async () => {
  const old = deferred<string>();
  const first = cacheRemember('test:race', 1000, () => old.promise);
  cacheBust('test:race');
  await cacheRemember('test:race', 1000, async () => 'new');
  old.resolve('old');
  await first;
  assert.equal(cacheGet('test:race'), 'new');
});

test('failed loads are not cached and can be retried', async () => {
  await assert.rejects(cacheRemember('test:failure', 1000, async () => { throw Error('offline'); }));
  assert.equal(await cacheRemember('test:failure', 1000, async () => 'recovered'), 'recovered');
});

test('expired values are reloaded and live entries remain bounded', async () => {
  cacheSet('test:expired', 'old', -1);
  assert.equal(await cacheRemember('test:expired', 1000, async () => 'fresh'), 'fresh');
  cacheBust('');
  for (let i = 0; i < 201; i++) cacheSet(`bounded:${i}`, i, 1000);
  assert.equal(cacheGet('bounded:0'), undefined);
  assert.equal(cacheGet('bounded:200'), 200);
  cacheBust('');
});

test('config reads coalesce and an admin invalidation wins against an older read', async (t) => {
  const old = deferred<any>();
  let calls = 0;
  mockQuery(t, prisma.appConfig, 'findUnique', () => {
    calls++;
    return calls === 1 ? old.promise : Promise.resolve({ data: {}, version: 2 });
  });
  bustConfigCache();
  const first = getConfig();
  const second = getConfig();
  assert.equal(calls, 1);
  bustConfigCache();
  await getConfig();
  old.resolve({ data: {}, version: 1 });
  await Promise.all([first, second]);
  const { getConfigVersion } = await import('../src/services/config');
  assert.equal(await getConfigVersion(), 2);
  assert.equal(calls, 2);
});

test('maintenance reads coalesce and respect invalidation', async (t) => {
  const old = deferred<any>();
  let calls = 0;
  mockQuery(t, prisma.maintenanceWindow, 'findUnique', () => {
    calls++;
    return calls === 1 ? old.promise : Promise.resolve({ enabled: true });
  });
  bustMaintenanceCache();
  const first = getMaintenance();
  const second = getMaintenance();
  assert.equal(calls, 1);
  bustMaintenanceCache();
  await getMaintenance();
  old.resolve(null);
  await Promise.all([first, second]);
  assert.equal((await getMaintenance()).enabled, true);
  assert.equal(calls, 2);
});

test('cached restrictions expire at their actual expiry', async (t) => {
  let now = 1000;
  t.mock.method(Date, 'now', () => now);
  mockQuery(t, prisma.userRestriction, 'findMany', async () => [
    { id: 'r', kind: 'LOGIN', reason: null, expiresAt: new Date(1500) },
  ]);
  bustRestrictions('test-user');
  assert.equal((await activeRestrictions('test-user')).length, 1);
  now = 2000;
  assert.equal((await activeRestrictions('test-user')).length, 0);
});

test('authentication overlaps independent checks and still rejects suspended/revoked/banned users', async (t) => {
  process.env.DATABASE_URL ??= 'postgresql://test:test@localhost:5432/test';
  const { requireAuth } = await import('../src/middleware/auth');
  const { signToken } = await import('../src/lib/jwt');
  const user = { id: 'auth-test', phone: '+10000000000', isActive: true, tokenVersion: 0 };
  let restrictions: any[] = [];
  const accountReady = deferred<any>();
  let restrictionStarted = false;
  mockQuery(t, prisma.user, 'findUnique', () => accountReady.promise);
  mockQuery(t, prisma.userRestriction, 'findMany', async () => {
    restrictionStarted = true;
    return restrictions;
  });
  const request = () => ({ headers: { authorization: `Bearer ${signToken({ sub: user.id, phone: user.phone, tv: 0 })}` } } as any);
  const req = request();
  let failure: any;
  const running = requireAuth(req, {} as any, (error) => { failure = error; });
  await Promise.resolve();
  assert.equal(restrictionStarted, true, 'restriction query starts before account query resolves');
  accountReady.resolve(user);
  await running;
  assert.equal(failure, undefined);
  assert.equal(req.userId, user.id);

  for (const scenario of ['suspended', 'revoked', 'banned', 'deleted']) {
    bustRestrictions(user.id);
    user.isActive = scenario !== 'suspended';
    user.tokenVersion = scenario === 'revoked' ? 1 : 0;
    restrictions = scenario === 'banned' ? [{ id: 'ban', kind: 'LOGIN', reason: null, expiresAt: null }] : [];
    prisma.user.findUnique = (() => Promise.resolve(scenario === 'deleted' ? null : user)) as any;
    const denied = request();
    await requireAuth(denied, {} as any, (error) => { failure = error; });
    assert.equal(failure.code, ['suspended', 'banned'].includes(scenario) ? 'ACCOUNT_SUSPENDED' : 'UNAUTHENTICATED');
    assert.equal(denied.userId, undefined);
  }
});

test('listing search burst uses one listing/count pair and preserves visibility filters', async (t) => {
  process.env.DATABASE_URL ??= 'postgresql://test:test@localhost:5432/test';
  const express = (await import('express')).default;
  const { listingsRouter } = await import('../src/routes/listings.routes');
  const { errorHandler } = await import('../src/middleware/error');
  cacheBust('listings:');
  const ready = deferred<any[]>();
  let reads = 0;
  let counts = 0;
  let bans = 0;
  let query: any;
  mockQuery(t, prisma.listing, 'findMany', (args) => { reads++; query = args; return ready.promise; });
  mockQuery(t, prisma.listing, 'count', async (args) => {
    counts++;
    assert.deepEqual(args.where, query.where);
    return 0;
  });
  mockQuery(t, prisma.userRestriction, 'findMany', async () => { bans++; return []; });
  const app = express();
  app.use('/listings', listingsRouter);
  app.use(errorHandler);
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>((resolve) => server.once('listening', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); cacheBust('listings:'); });
  const address = server.address() as { port: number };
  const url = `http://127.0.0.1:${address.port}/listings?limit=20&offset=0&city=Douala`;
  const requests = Array.from({ length: 10 }, () => fetch(url));
  // Release after the first query starts; in-flight and cache hits must both
  // avoid an extra listing/count query regardless of network scheduling.
  while (!reads) await new Promise((resolve) => setTimeout(resolve, 1));
  ready.resolve([]);
  for (const response of await Promise.all(requests)) {
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { total: 0, items: [] });
  }
  assert.equal(reads, 1);
  assert.equal(counts, 1);
  assert.equal(bans, 0);
  assert.equal(query.take, 20);
  assert.equal(query.where.available, true);
  assert.deepEqual(query.where.status.in, ['ACTIVE', 'BOOSTED']);
  assert.equal(query.where.owner.OR.length, 4);
  assert.equal(query.where.owner.restrictions.none.kind, 'SHADOW_BAN');
  assert.equal(query.where.owner.restrictions.none.revokedAt, null);
  assert.deepEqual(query.where.city, { contains: 'Douala', mode: 'insensitive' });
  const invalid = await fetch(url.replace('limit=20', 'limit=1.5'));
  assert.equal(invalid.status, 422);
});
