import { Request, Response, NextFunction } from 'express';

/** Wrap an async handler so thrown errors reach the error middleware. */
export function asyncHandler(
  fn: (req: Request, res: Response, next: NextFunction) => Promise<unknown>
) {
  return (req: Request, res: Response, next: NextFunction) => {
    fn(req, res, next).catch(next);
  };
}

/**
 * Stable, machine-readable error identifiers. The client branches on these —
 * never on the human-readable message, which is French prose and free to change.
 */
export type ErrorCode =
  | 'VALIDATION_FAILED'
  | 'UNAUTHENTICATED'
  | 'ACCOUNT_NOT_FOUND'
  | 'INVALID_PASSWORD'
  | 'NO_PASSWORD_SET'
  | 'TOKEN_EXPIRED'
  | 'FORBIDDEN'
  | 'NOT_FOUND'
  | 'ALREADY_EXISTS'
  | 'RATE_LIMITED'
  | 'OTP_RATE_LIMITED'
  | 'OTP_INVALID'
  | 'OTP_EXPIRED'
  | 'OTP_LOCKED'
  | 'OWNER_REQUIRED'
  | 'CONFLICT'
  | 'INTERNAL';

export class ApiError extends Error {
  status: number;
  code: ErrorCode;
  constructor(status: number, message: string, code: ErrorCode = 'INTERNAL') {
    super(message);
    this.status = status;
    this.code = code;
  }
}
