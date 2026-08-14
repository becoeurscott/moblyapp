/**
 * End-to-end realtime chat check.
 *
 *   npx tsx scripts/chat-test.ts
 *
 * Creates a buyer and a listing owner, opens a thread from a listing id,
 * connects the owner's socket, and verifies the message arrives in real time.
 */
import WebSocket from 'ws';
import { prisma } from '../src/lib/prisma';

const B = 'http://127.0.0.1:4000/api/v1';
const WS = 'ws://127.0.0.1:4000/ws';

async function call(path: string, opts: { method?: string; body?: unknown; token?: string } = {}) {
  const res = await fetch(B + path, {
    method: opts.method ?? 'GET',
    headers: {
      'Content-Type': 'application/json',
      ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}),
    },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  let json: any = null;
  try {
    json = await res.json();
  } catch {
    /* 204 */
  }
  return { status: res.status, json };
}

async function makeUser(phone: string, email: string) {
  const start = await call('/auth/signup/start', {
    method: 'POST',
    body: { fullName: 'Chat Test', phone, email, password: 'Espace2026' },
  });
  if (!start.json?.devCode) return null;
  const v = await call('/auth/signup/verify', {
    method: 'POST',
    body: { fullName: 'Chat Test', phone, email, password: 'Espace2026', code: start.json.devCode },
  });
  return v.json?.token ? { token: v.json.token, id: v.json.user.id } : null;
}

function connect(token: string, label: string) {
  return new Promise<{ socket: WebSocket; received: any[] }>((resolve, reject) => {
    const socket = new WebSocket(WS);
    const received: any[] = [];
    const timer = setTimeout(() => reject(new Error(`${label}: no ready frame`)), 10_000);

    socket.on('open', () => socket.send(JSON.stringify({ type: 'auth', token })));
    socket.on('message', (raw) => {
      const event = JSON.parse(raw.toString());
      if (event.type === 'ready') {
        clearTimeout(timer);
        resolve({ socket, received });
        return;
      }
      received.push(event);
      console.log(`    [${label}] <- ${event.type}${event.message ? ` "${event.message.text}"` : ''}`);
    });
    socket.on('error', reject);
  });
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const stamp = Date.now().toString().slice(-6);
  const buyer = await makeUser(`+2376903${stamp.slice(0, 5)}`, `buy${stamp}@t.cm`);
  const owner = await makeUser(`+2376904${stamp.slice(0, 5)}`, `own${stamp}@t.cm`);
  if (!buyer || !owner) {
    console.log('  could not create users (rate limited?) — retry shortly');
    return;
  }

  // A listing owned by `owner`, so the thread can be opened from the listing
  // alone — the client never says who the owner is.
  const listing = await prisma.listing.create({
    data: {
      title: 'Studio test réel',
      category: 'Studios',
      city: 'Douala',
      priceFcfa: 50000,
      ownerId: owner.id,
      tags: ['chat-test'],
    },
  });
  console.log(`  buyer=${buyer.id}\n  owner=${owner.id}\n  listing=${listing.id}\n`);

  console.log('— owner connects —');
  const ownerConn = await connect(owner.token, 'owner');
  console.log('  authenticated\n');

  console.log('— buyer opens a thread from the LISTING id only —');
  const t = await call('/threads', {
    method: 'POST',
    token: buyer.token,
    body: { listingId: listing.id },
  });
  const threadId = t.json?.thread?.id;
  console.log(`  thread ${threadId} (owner resolved server-side: ${t.status})\n`);

  console.log('— buyer sends; owner should receive over the socket —');
  await call(`/threads/${threadId}/messages`, {
    method: 'POST',
    token: buyer.token,
    body: { text: 'Bonjour, ce studio est-il disponible ?', clientId: 'c1' },
  });
  await wait(1200);
  const got = ownerConn.received.find((e) => e.type === 'message');
  console.log(got ? '  PASS  delivered in real time' : '  **FAIL** nothing arrived');

  console.log('\n— idempotency: same clientId sent twice —');
  const again = await call(`/threads/${threadId}/messages`, {
    method: 'POST',
    token: buyer.token,
    body: { text: 'Bonjour, ce studio est-il disponible ?', clientId: 'c1' },
  });
  console.log(
    again.json?.duplicate
      ? '  PASS  retry resolved to the existing message (no double-post)'
      : '  **FAIL** duplicated'
  );

  console.log('\n— unread count on the owner’s thread list —');
  const list = await call('/threads', { token: owner.token });
  const row = list.json?.items?.find((i: any) => i.id === threadId);
  console.log(
    row?.unread === 1
      ? `  PASS  unread = ${row.unread}`
      : `  **FAIL** unread = ${row?.unread}`
  );

  console.log('\n— outsider cannot read the thread —');
  const outsider = await makeUser(`+2376905${stamp.slice(0, 5)}`, `out${stamp}@t.cm`);
  if (outsider) {
    const peek = await call(`/threads/${threadId}/messages`, { token: outsider.token });
    console.log(
      peek.status === 403
        ? `  PASS  blocked (${peek.json?.code})`
        : `  **FAIL** status ${peek.status}`
    );
  }

  console.log('\n— unauthenticated socket is dropped —');
  await new Promise<void>((resolve) => {
    const s = new WebSocket(WS);
    s.on('open', () => s.send(JSON.stringify({ type: 'typing', threadId, typing: true })));
    s.on('message', (raw) => {
      const e = JSON.parse(raw.toString());
      if (e.type === 'error') {
        console.log(`  PASS  refused: "${e.message}"`);
        s.close();
        resolve();
      }
    });
    setTimeout(() => {
      s.close();
      resolve();
    }, 4000);
  });

  ownerConn.socket.close();
  await prisma.listing.delete({ where: { id: listing.id } }).catch(() => {});
  await prisma.$disconnect();
  console.log('\n  done');
}

main();
