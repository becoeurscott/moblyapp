import { AsyncLocalStorage } from 'node:async_hooks';
import { performance } from 'node:perf_hooks';
import type { RequestHandler } from 'express';

interface RequestMetrics { databaseCalls: number; databaseMs: number }
const context = new AsyncLocalStorage<RequestMetrics>();

/** Query arguments, tokens, bodies and URL query strings are never logged. */
export async function measureDatabase<T>(operation: string, run: () => Promise<T>): Promise<T> {
  const metrics = context.getStore();
  const start = performance.now();
  if (metrics) metrics.databaseCalls++;
  try {
    return await run();
  } finally {
    const durationMs = performance.now() - start;
    if (metrics) metrics.databaseMs += durationMs;
    if (durationMs >= 500) console.warn(JSON.stringify({
      event: 'slow_database_operation', operation, durationMs: Math.round(durationMs),
    }));
  }
}

export const requestPerformance: RequestHandler = (req, res, next) => {
  const start = performance.now();
  const metrics: RequestMetrics = { databaseCalls: 0, databaseMs: 0 };
  res.once('finish', () => {
    const durationMs = performance.now() - start;
    if (durationMs >= 1000 || process.env.PERFORMANCE_LOG === 'true') {
      console.info(JSON.stringify({
        event: 'request_performance', requestId: req.id, method: req.method,
        route: req.route?.path ?? 'unmatched', status: res.statusCode,
        durationMs: Math.round(durationMs), databaseCalls: metrics.databaseCalls,
        // Sum of operation durations, including network/pool waits. Parallel
        // operations can legitimately exceed total request wall-clock time.
        databaseMs: Math.round(metrics.databaseMs),
      }));
    }
  });
  context.run(metrics, next);
};
