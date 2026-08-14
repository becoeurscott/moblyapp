import { WebSocketServer, WebSocket, RawData } from 'ws';
import type { Server } from 'node:http';
import { verifyToken } from '../lib/jwt';
import { prisma } from '../lib/prisma';

/**
 * Real-time delivery for chat.
 *
 * Shape of the system: **messages are SENT over REST and RECEIVED over the
 * socket.** Sending over HTTP gives a status code, a retry story and
 * idempotency via `clientId` — all things a socket frame lacks on a network
 * that drops. The socket only pushes what already exists in the database, so a
 * disconnect never loses a message: the client refetches history on reconnect.
 *
 * Connections are indexed by user, not by thread. A user with three devices
 * has three sockets; a message fans out to whichever of them are live, and the
 * rest see it when they next sync.
 */

type ClientEvent =
  | { type: 'auth'; token: string }
  | { type: 'typing'; threadId: string; typing: boolean }
  | { type: 'read'; threadId: string }
  | { type: 'ping' };

export type ServerEvent =
  | { type: 'ready'; userId: string }
  | { type: 'message'; threadId: string; message: unknown }
  | { type: 'typing'; threadId: string; userId: string; typing: boolean }
  | { type: 'read'; threadId: string; userId: string; at: string }
  | { type: 'presence'; userId: string; online: boolean }
  | { type: 'pong' }
  | { type: 'error'; message: string };

interface Client {
  socket: WebSocket;
  userId: string;
  /** Cleared once authenticated; an unauthenticated socket is dropped. */
  authTimer?: NodeJS.Timeout;
  alive: boolean;
}

/** userId -> that user's live sockets (one per device/tab). */
const byUser = new Map<string, Set<Client>>();

/** How long an unauthenticated socket may stay open. */
const AUTH_GRACE_MS = 10_000;
/** Heartbeat — mobile networks drop connections without a FIN. */
const HEARTBEAT_MS = 30_000;

function send(socket: WebSocket, event: ServerEvent) {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(event));
  }
}

function register(client: Client) {
  let set = byUser.get(client.userId);
  if (!set) {
    set = new Set();
    byUser.set(client.userId, set);
  }
  set.add(client);
}

function unregister(client: Client) {
  const set = byUser.get(client.userId);
  if (!set) return;
  set.delete(client);
  if (set.size === 0) byUser.delete(client.userId);
}

export function isOnline(userId: string): boolean {
  return byUser.has(userId);
}

/** Push an event to every live socket of these users. */
export function emitToUsers(userIds: string[], event: ServerEvent) {
  for (const id of new Set(userIds)) {
    const set = byUser.get(id);
    if (!set) continue;
    for (const client of set) send(client.socket, event);
  }
}

/** Everyone in a thread, so callers don't each re-query participants. */
export async function threadParticipantIds(threadId: string): Promise<string[]> {
  const parts = await prisma.threadParticipant.findMany({
    where: { threadId },
    select: { userId: true },
  });
  return parts.map((p) => p.userId);
}

/** Push a newly persisted message to everyone in its thread except the sender. */
export async function broadcastMessage(
  threadId: string,
  message: { senderId: string } & Record<string, unknown>
) {
  const ids = await threadParticipantIds(threadId);
  const recipients = ids.filter((id) => id !== message.senderId);
  emitToUsers(recipients, { type: 'message', threadId, message });
}

export function attachRealtime(server: Server, path = '/ws') {
  const wss = new WebSocketServer({ server, path });

  wss.on('connection', (socket: WebSocket) => {
    const client: Client = { socket, userId: '', alive: true };

    // The token arrives in the first frame, never in the URL: query strings
    // land in access logs and proxy history, and an access token there is a
    // credential sitting in plaintext on disk.
    client.authTimer = setTimeout(() => {
      send(socket, { type: 'error', message: 'Authentification requise' });
      socket.close(4401, 'unauthenticated');
    }, AUTH_GRACE_MS);

    socket.on('pong', () => {
      client.alive = true;
    });

    socket.on('message', async (raw: RawData) => {
      let event: ClientEvent;
      try {
        event = JSON.parse(raw.toString());
      } catch {
        return send(socket, { type: 'error', message: 'Message invalide' });
      }

      if (event.type === 'auth') {
        try {
          const payload = verifyToken(event.token);
          const user = await prisma.user.findUnique({
            where: { id: payload.sub },
            select: { id: true },
          });
          if (!user) throw new Error('unknown user');

          clearTimeout(client.authTimer);
          client.userId = user.id;
          register(client);
          send(socket, { type: 'ready', userId: user.id });

          // Tell this user's conversation partners they're online. Scoped to
          // people they already talk to — presence is not public.
          const threads = await prisma.threadParticipant.findMany({
            where: { userId: user.id },
            select: { threadId: true },
          });
          const peers = await prisma.threadParticipant.findMany({
            where: {
              threadId: { in: threads.map((t) => t.threadId) },
              userId: { not: user.id },
            },
            select: { userId: true },
          });
          emitToUsers(
            peers.map((p) => p.userId),
            { type: 'presence', userId: user.id, online: true }
          );
        } catch {
          send(socket, { type: 'error', message: 'Session invalide' });
          socket.close(4401, 'unauthenticated');
        }
        return;
      }

      // Everything past auth requires an identified socket.
      if (!client.userId) {
        return send(socket, { type: 'error', message: 'Authentification requise' });
      }

      switch (event.type) {
        case 'ping':
          send(socket, { type: 'pong' });
          break;

        case 'typing': {
          // Membership is re-checked here — a socket must not be able to
          // broadcast into a thread it doesn't belong to.
          const member = await prisma.threadParticipant.findUnique({
            where: { threadId_userId: { threadId: event.threadId, userId: client.userId } },
            select: { id: true },
          });
          if (!member) return;
          const ids = await threadParticipantIds(event.threadId);
          emitToUsers(
            ids.filter((id) => id !== client.userId),
            { type: 'typing', threadId: event.threadId, userId: client.userId, typing: event.typing }
          );
          break;
        }

        case 'read': {
          const member = await prisma.threadParticipant.findUnique({
            where: { threadId_userId: { threadId: event.threadId, userId: client.userId } },
            select: { id: true },
          });
          if (!member) return;
          const now = new Date();
          await prisma.$transaction([
            prisma.message.updateMany({
              where: { threadId: event.threadId, senderId: { not: client.userId }, read: false },
              data: { read: true, readAt: now },
            }),
            prisma.threadParticipant.update({
              where: { threadId_userId: { threadId: event.threadId, userId: client.userId } },
              data: { unreadCount: 0, lastReadAt: now },
            }),
          ]);
          const ids = await threadParticipantIds(event.threadId);
          emitToUsers(
            ids.filter((id) => id !== client.userId),
            {
              type: 'read',
              threadId: event.threadId,
              userId: client.userId,
              at: now.toISOString(),
            }
          );
          break;
        }
      }
    });

    socket.on('close', async () => {
      clearTimeout(client.authTimer);
      if (!client.userId) return;
      unregister(client);
      // Only announce offline once the user's *last* socket goes — otherwise
      // closing one device would mark them away while another is still open.
      if (!isOnline(client.userId)) {
        const threads = await prisma.threadParticipant.findMany({
          where: { userId: client.userId },
          select: { threadId: true },
        });
        const peers = await prisma.threadParticipant.findMany({
          where: {
            threadId: { in: threads.map((t) => t.threadId) },
            userId: { not: client.userId },
          },
          select: { userId: true },
        });
        emitToUsers(
          peers.map((p) => p.userId),
          { type: 'presence', userId: client.userId, online: false }
        );
      }
    });

    socket.on('error', () => socket.close());
  });

  // Drop sockets that stopped answering. Mobile networks routinely vanish
  // without closing the connection, so without this the map fills with
  // half-open sockets that look online forever.
  const heartbeat = setInterval(() => {
    for (const set of byUser.values()) {
      for (const client of set) {
        if (!client.alive) {
          client.socket.terminate();
          continue;
        }
        client.alive = false;
        client.socket.ping();
      }
    }
  }, HEARTBEAT_MS);

  wss.on('close', () => clearInterval(heartbeat));
  return wss;
}
