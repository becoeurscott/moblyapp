import { PrismaClient } from '@prisma/client';
import { measureDatabase } from './performance';

export const prisma = new PrismaClient({
  log: process.env.NODE_ENV === 'production' ? ['error'] : ['warn', 'error'],
});

prisma.$use((params, next) =>
  measureDatabase(`${params.model ?? 'raw'}.${params.action}`, () => next(params))
);
