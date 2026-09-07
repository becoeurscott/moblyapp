import { Router } from 'express';
import { asyncHandler } from '../lib/http';
import { getConfig, configVersionSnapshot, toPublicConfig } from '../services/config';

export const configRouter = Router();

/**
 * `GET /config` — what the app is allowed to know about its own configuration.
 *
 * Public and unauthenticated on purpose: the sign-in screen needs to know which
 * sign-in methods are enabled *before* anyone has a token, and a force-update
 * screen has to be reachable by a build too old to authenticate.
 *
 * `no-store` because a cached copy would keep a disabled feature alive on the
 * client long after an operator switched it off — the whole point is that the
 * change lands in seconds.
 */
configRouter.get(
  '/',
  asyncHandler(async (_req, res) => {
    const doc = await getConfig();
    res.set('Cache-Control', 'no-store');
    res.json({
      ...toPublicConfig(doc),
      version: configVersionSnapshot(),
      serverTime: new Date().toISOString(),
    });
  })
);
