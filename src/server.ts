import { createApp } from './app';
import { env } from './config/env';
import { prisma } from './lib/prisma';
import { attachRealtime } from './realtime/hub';
import { primeConfig } from './services/config';

const app = createApp();

// Load the remote configuration before serving. The rate limiters and the
// socket hub read it synchronously, so without this the first requests after a
// deploy would run on the built-in defaults instead of the operator's settings.
primeConfig().catch((err) => console.error('[config] prime failed:', err));

const server = app.listen(env.port, () => {
  console.log(
    `🚀 mobly-backend listening on http://localhost:${env.port}${env.apiPrefix} (${env.nodeEnv})`
  );
  console.log(`   realtime chat on ws://localhost:${env.port}/ws`);
});

// Shares the HTTP server, so one port serves both REST and the socket.
attachRealtime(server);

async function shutdown(signal: string) {
  console.log(`\n${signal} received, shutting down…`);
  server.close(async () => {
    await prisma.$disconnect();
    process.exit(0);
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
