import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import { env } from './config/env';
import { api } from './routes';
import { errorHandler, notFound } from './middleware/error';
import { globalLimiter, requestId, corsOrigin } from './middleware/security';

export function createApp() {
  const app = express();

  // Behind Render/Railway/Nginx the client IP arrives in X-Forwarded-For.
  // Rate limiting keys off req.ip, so getting this wrong either lumps every
  // user into one bucket or lets a spoofed header dodge the limit entirely.
  if (env.trustProxy !== false) app.set('trust proxy', env.trustProxy);

  // Security headers first, before anything can respond.
  app.use(
    helmet({
      // JSON API with no HTML of its own, so the default CSP only gets in the
      // way. TLS/HSTS is the platform terminator's job.
      contentSecurityPolicy: false,
      crossOriginResourcePolicy: { policy: 'cross-origin' },
    })
  );

  app.use(requestId);

  app.use(
    cors({
      origin: corsOrigin(),
      credentials: true,
      exposedHeaders: ['X-Request-Id', 'RateLimit-Remaining', 'RateLimit-Reset'],
    })
  );

  app.use(express.json({ limit: '2mb' }));
  app.use(globalLimiter);

  // Carry the request id into every log line so a reported failure can be
  // traced to one entry.
  morgan.token('rid', (req) => (req as express.Request).id ?? '-');
  app.use(morgan(env.isProd ? ':rid :method :url :status :response-time ms' : 'dev'));

  app.get('/', (_req, res) =>
    res.json({ service: 'mobly-backend', api: env.apiPrefix, health: `${env.apiPrefix}/health` })
  );
  app.use(env.apiPrefix, api);
  // Legacy alias so clients pinned to /api keep working after API_PREFIX moved.
  if (env.apiPrefix !== '/api') app.use('/api', api);

  app.use(notFound);
  app.use(errorHandler);

  return app;
}
