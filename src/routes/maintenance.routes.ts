import { Router } from 'express';
import { asyncHandler } from '../lib/http';
import { getMaintenance, serializeMaintenance } from '../services/maintenance';

export const maintenanceRouter = Router();

/**
 * GET /api/v1/maintenance — public status probe.
 *
 * Deliberately unauthenticated and allow-listed past the gate: this is how a
 * blocked app learns it may come back. Cheap (in-memory cache), so the client
 * can poll it every few seconds while the blocking screen is up.
 */
maintenanceRouter.get(
  '/',
  asyncHandler(async (_req, res) => {
    const state = await getMaintenance();
    // Never cache at the edge — a stale "we're down" would outlive the window.
    res.set('Cache-Control', 'no-store');
    res.json(serializeMaintenance(state));
  })
);
