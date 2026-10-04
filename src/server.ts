import http, { type IncomingMessage, type ServerResponse } from 'node:http';

const port = parseInt(process.env.PORT ?? '4000', 10);
const host = '0.0.0.0';
const apiPrefix = (process.env.API_PREFIX ?? '/api').replace(/\/+$/, '') || '/api';

type Handler = (req: IncomingMessage, res: ServerResponse) => void;
let ready = false;
let bootStage = 'opening port';
let bootError: string | null = null;
let activeHandler: Handler = (req, res) => {
  const url = req.url ?? '/';
  const publicBootError = process.env.NODE_ENV === 'production' && bootError ? 'boot failed' : bootError;
  if (url === '/' || url === `${apiPrefix}/health` || (apiPrefix !== '/api' && url === '/api/health')) {
    res.writeHead(ready ? 200 : 503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ service: 'mobly-backend', ready, api: apiPrefix, bootStage, bootError: publicBootError }));
    return;
  }
  res.writeHead(503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify({ error: 'Server is starting. Please retry in a moment.', bootStage, bootError: publicBootError }));
};

const server = http.createServer((req, res) => activeHandler(req, res));

server.listen(port, host, () => {
  console.log(`🚀 mobly-backend port open on http://${host}:${port}${apiPrefix}`);
  void bootApp();
});

server.on('error', (err) => {
  console.error('[server] listen failed:', err);
});

async function bootApp() {
  try {
    bootStage = 'loading env';
    const { env } = await import('./config/env');
    bootStage = 'loading app';
    const { createApp } = await import('./app');
    bootStage = 'loading realtime';
    const { attachRealtime } = await import('./realtime/hub');
    bootStage = 'loading config service';
    const { primeConfig } = await import('./services/config');
    bootStage = 'loading boost service';
    const { startBoostExpiry } = await import('./services/boostExpiry');

    bootStage = 'creating app';
    const app = createApp();
    activeHandler = (req, res) => app(req, res);
    attachRealtime(server);
    ready = true;
    bootStage = 'ready';

    console.log(`✅ mobly-backend ready on http://${host}:${env.port}${env.apiPrefix} (${env.nodeEnv})`);
    console.log(`   realtime chat on ws://${host}:${env.port}/ws`);

    primeConfig().catch((err) => console.error('[config] prime failed:', err));
    startBoostExpiry();
  } catch (err) {
    bootError = err instanceof Error ? err.message : String(err);
    bootStage = 'failed';
    console.error('[server] boot failed:', err);
  }
}

async function shutdown(signal: string) {
  console.log(`\n${signal} received, shutting down…`);
  server.close(async () => {
    try {
      const { prisma } = await import('./lib/prisma');
      await prisma.$disconnect();
    } catch (err) {
      console.error('[server] shutdown cleanup failed:', err);
    }
    process.exit(0);
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
