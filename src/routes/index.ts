import { Router } from 'express';
import { authRouter } from './auth.routes';
import { signupRouter } from './signup.routes';
import { listingsRouter } from './listings.routes';
import { ownerRouter } from './owner.routes';
import { boostRouter } from './boost.routes';
import { favoritesRouter } from './favorites.routes';
import { chatRouter } from './chat.routes';
import { devicesRouter } from './devices.routes';
import { miscRouter, notificationsRouter, reviewsRouter, usersRouter } from './misc.routes';
import { visitsRouter, listingVisitsRouter } from './visits.routes';
import { analyticsRouter } from './analytics.routes';
import { oauthRouter } from './oauth.routes';
import { uploadsRouter } from './uploads.routes';
import { adminRouter } from './admin.routes';
import { cronRouter } from './cron.routes';
import { verificationRouter } from './verification.routes';
import { maintenanceRouter } from './maintenance.routes';
import { maintenanceGate } from '../middleware/maintenance';

export const api = Router();

api.get('/health', (_req, res) => res.json({ ok: true, service: 'mobly-backend' }));

// Everything below this line is gated by the maintenance window. Must stay
// FIRST so no route can be reached around it; /health above is deliberately
// mounted before the gate as well as allow-listed inside it.
api.use(maintenanceGate);

api.use('/maintenance', maintenanceRouter); // public: is the app down, until when

api.use('/auth', authRouter);
api.use('/auth', oauthRouter);   // /auth/apple, /auth/google (later)
api.use('/auth/signup', signupRouter);
// /auth/oauth lives on the signup router (it can end in signup or sign-in).
api.use('/auth', signupRouter);
api.use('/listings', listingsRouter);
api.use('/listings', reviewsRouter); // GET/POST /listings/:id/reviews
api.use('/listings/:id/visits', listingVisitsRouter);
api.use('/', visitsRouter); // /owner/visits, /me/visits, /visits/:id
api.use('/', analyticsRouter); // /sessions/*, /events, /me/sessions
api.use('/uploads', uploadsRouter); // /uploads/photos
api.use('/admin', adminRouter);     // full admin surface (requireAdmin)
api.use('/owner', ownerRouter);
api.use('/boost', boostRouter);
api.use('/favorites', favoritesRouter);
api.use('/threads', chatRouter);
api.use('/devices', devicesRouter);
api.use('/notifications', notificationsRouter);
api.use('/users', usersRouter);
api.use('/cron', cronRouter);
api.use('/verification', verificationRouter); // Didit KYC: session, status, webhook
api.use('/', miscRouter); // /geo, /categories
