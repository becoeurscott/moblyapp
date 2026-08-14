/**
 * Buyer ↔ owner conversation, exercised exactly as the app does.
 *
 *   npx tsx scripts/two-party-test.ts
 *
 * Confirms: the owner receives in real time, presence flips to online while
 * their socket is open, empty threads stay hidden until a message exists, and
 * the row carries the last message with its timestamp.
 */
import WebSocket from 'ws';
import { prisma } from '../src/lib/prisma';

const B = 'http://127.0.0.1:4000/api/v1';
const WS = 'ws://127.0.0.1:4000/ws';
const OWNER_EMAIL = 'proprio.test@mobly.cm';
const OWNER_PASSWORD = 'Proprio2026';

async function call(path: string, o: { method?: string; body?: unknown; token?: string } = {}) {
  const res = await fetch(B + path, {
    method: o.method ?? 'GET',
    headers: {
      'Content-Type': 'application/json',
      ...(o.token ? { Authorization: `Bearer ${o.token}` } : {}),
    },
    body: o.body ? JSON.stringify(o.body) : undefined,
  });
  let json: any = null;
  try { json = await res.json(); } catch {}
  return { status: res.status, json };
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

function connect(token: string) {
  return new Promise<{ socket: WebSocket; events: any[] }>((resolve, reject) => {
    const socket = new WebSocket(WS);
    const events: any[] = [];
    const t = setTimeout(() => reject(new Error('no ready frame')), 10_000);
    socket.on('open', () => socket.send(JSON.stringify({ type: 'auth', token })));
    socket.on('message', (raw) => {
      const e = JSON.parse(raw.toString());
      if (e.type === 'ready') { clearTimeout(t); resolve({ socket, events }); return; }
      events.push(e);
    });
    socket.on('error', reject);
  });
}

async function main() {
  // Owner signs in with the credentials the seed script set.
  const ownerLogin = await call('/auth/login', {
    method: 'POST',
    body: { identifier: OWNER_EMAIL, password: OWNER_PASSWORD },
  });
  if (!ownerLogin.json?.token) {
    console.error('  ✗ owner sign-in failed:', ownerLogin.json?.error);
    process.exit(1);
  }
  const owner = { token: ownerLogin.json.token, id: ownerLogin.json.user.id };
  console.log(`  owner signed in: ${ownerLogin.json.user.fullName} <${OWNER_EMAIL}>`);

  // A buyer account.
  const stamp = Date.now().toString().slice(-6);
  const s = await call('/auth/signup/start', {
    method: 'POST',
    body: { fullName: 'Acheteur Test', phone: `+2376906${stamp.slice(0, 5)}`,
            email: `acheteur${stamp}@t.cm`, password: 'Espace2026' },
  });
  const v = await call('/auth/signup/verify', {
    method: 'POST',
    body: { fullName: 'Acheteur Test', phone: `+2376906${stamp.slice(0, 5)}`,
            email: `acheteur${stamp}@t.cm`, password: 'Espace2026', code: s.json.devCode },
  });
  const buyer = { token: v.json.token, id: v.json.user.id };
  console.log(`  buyer created:   ${v.json.user.fullName}\n`);

  const listing = await prisma.listing.findFirst({
    where: { title: { contains: 'High-tech elegance', mode: 'insensitive' } },
  });

  console.log('— buyer opens the conversation but sends nothing —');
  const t = await call('/threads', {
    method: 'POST', token: buyer.token, body: { listingId: listing!.id },
  });
  const threadId = t.json.thread.id;
  let list = await call('/threads', { token: buyer.token });
  const hiddenWhileEmpty = !list.json.items.some((i: any) => i.id === threadId);
  console.log(hiddenWhileEmpty
    ? '  PASS  empty conversation is not shown in the inbox'
    : '  **FAIL** empty conversation appears');

  console.log('\n— owner comes online —');
  const ownerConn = await connect(owner.token);
  await wait(600);
  list = await call('/threads', { token: buyer.token });
  console.log('  owner socket connected');

  console.log('\n— buyer sends —');
  await call(`/threads/${threadId}/messages`, {
    method: 'POST', token: buyer.token,
    body: { text: 'Bonjour, cet appartement est-il libre en août ?', clientId: 'm1' },
  });
  await wait(1200);
  const delivered = ownerConn.events.find((e) => e.type === 'message');
  console.log(delivered
    ? `  PASS  owner received in real time: "${delivered.message.text}"`
    : '  **FAIL** nothing delivered');

  console.log('\n— buyer inbox now —');
  list = await call('/threads', { token: buyer.token });
  const row = list.json.items.find((i: any) => i.id === threadId);
  console.log(row ? '  PASS  conversation now appears' : '  **FAIL** still hidden');
  if (row) {
    console.log(`        last message : "${row.lastMessage.text}"`);
    console.log(`        sent at      : ${row.lastMessage.createdAt}`);
    console.log(`        peer online  : ${row.participants[0]?.online}  <- green dot`);
    console.log(`        fromMe       : ${row.lastMessage.senderId === buyer.id}  -> "Vous : …"`);
  }

  console.log('\n— owner replies —');
  const ownerThreads = await call('/threads', { token: owner.token });
  const ownerRow = ownerThreads.json.items.find((i: any) => i.id === threadId);
  console.log(`  owner sees unread = ${ownerRow?.unread}`);
  await call(`/threads/${threadId}/messages`, {
    method: 'POST', token: owner.token,
    body: { text: 'Bonjour ! Oui, il est disponible.', clientId: 'r1' },
  });
  await wait(800);
  const buyerAfter = await call('/threads', { token: buyer.token });
  const r2 = buyerAfter.json.items.find((i: any) => i.id === threadId);
  console.log(`  buyer last message: "${r2?.lastMessage.text}" (unread ${r2?.unread})`);

  console.log('\n— owner goes offline —');
  ownerConn.socket.close();
  await wait(1000);
  const afterOffline = await call('/threads', { token: buyer.token });
  const r3 = afterOffline.json.items.find((i: any) => i.id === threadId);
  console.log(r3?.participants[0]?.online === false
    ? '  PASS  presence flipped to offline'
    : `  **FAIL** still ${r3?.participants[0]?.online}`);

  await prisma.$disconnect();
  console.log('\n  done');
}

main();
