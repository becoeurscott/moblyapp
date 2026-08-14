import { createApp } from './app';
import { env } from './config/env';
import { prisma } from './lib/prisma';
import { attachRealtime } from './realtime/hub';

const app = createApp();

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
