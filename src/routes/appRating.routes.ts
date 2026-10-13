import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth } from '../middleware/auth';

export const appRatingRouter = Router();

appRatingRouter.get('/status', requireAuth, asyncHandler(async (req, res) => {
  const row = await prisma.appRating.findUnique({ where: { userId: req.userId! } });
  if (row?.promptAgain) {
    await prisma.appRating.update({ where: { userId: req.userId! }, data: { promptAgain: false } });
  }
  res.json({ shouldPrompt: !row || row.promptAgain, adminRequested: row?.promptAgain ?? false });
}));

appRatingRouter.post('/', requireAuth, asyncHandler(async (req, res) => {
  const parsed = z.object({ rating: z.number().int().min(1).max(5), comment: z.string().trim().max(2000).optional() }).safeParse(req.body);
  if (!parsed.success) throw new ApiError(400, 'Note invalide', 'VALIDATION_FAILED');
  const rating = await prisma.appRating.upsert({
    where: { userId: req.userId! },
    create: { userId: req.userId!, rating: parsed.data.rating, comment: parsed.data.comment || null },
    update: { rating: parsed.data.rating, comment: parsed.data.comment || null, promptAgain: false, submittedAt: new Date() },
  });
  res.status(201).json({ rating: { rating: rating.rating, submittedAt: rating.submittedAt } });
}));
