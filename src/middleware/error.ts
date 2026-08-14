import { Request, Response, NextFunction } from 'express';
import { ZodError } from 'zod';
import { Prisma } from '@prisma/client';
import { ApiError } from '../lib/http';
import { env } from '../config/env';

/**
 * Every error leaves as `{ error, code, requestId }`.
 *
 * `error` is French prose safe to show a user; `code` is the stable identifier
 * the client branches on. Without a code the app ends up string-matching
 * messages, which breaks the moment any wording changes.
 */
export function errorHandler(err: unknown, req: Request, res: Response, _next: NextFunction) {
  const requestId = req.id;

  if (err instanceof ApiError) {
    // `fields` lets a form pin each message to its own input instead of
    // showing one banner for the whole thing.
    const fields = (err as ApiError & { fields?: Record<string, string> }).fields;
    return res.status(err.status).json({
      error: err.message,
      code: err.code,
      ...(fields ? { fields } : {}),
      requestId,
    });
  }

  // A malformed body is the client's mistake, not a server fault. Without this
  // it lands in the catch-all as a 500 and fills the logs with "[unhandled]"
  // noise that looks like a real incident.
  if (err instanceof SyntaxError && 'body' in (err as object)) {
    return res.status(400).json({
      error: 'Requête invalide',
      code: 'VALIDATION_FAILED',
      requestId,
    });
  }

  if (err instanceof ZodError) {
    return res.status(422).json({
      error: 'Données invalides',
      code: 'VALIDATION_FAILED',
      details: err.flatten(),
      requestId,
    });
  }

  // Translate the Prisma errors that are really client mistakes, so a unique
  // constraint doesn't surface to the user as a generic 500.
  if (err instanceof Prisma.PrismaClientKnownRequestError) {
    if (err.code === 'P2002') {
      return res
        .status(409)
        .json({ error: 'Cette valeur est déjà utilisée', code: 'ALREADY_EXISTS', requestId });
    }
    if (err.code === 'P2025') {
      return res.status(404).json({ error: 'Introuvable', code: 'NOT_FOUND', requestId });
    }
  }

  // Anything reaching here is a real bug. Log it against the id and return
  // nothing internal — stack traces and driver messages leak schema and paths.
  console.error(`[unhandled] rid=${requestId}`, err);
  return res.status(500).json({
    error: 'Une erreur est survenue. Réessayez.',
    code: 'INTERNAL',
    requestId,
    ...(env.isProd ? {} : { debug: err instanceof Error ? err.message : String(err) }),
  });
}

export function notFound(req: Request, res: Response) {
  res.status(404).json({ error: 'Ressource introuvable', code: 'NOT_FOUND', requestId: req.id });
}
