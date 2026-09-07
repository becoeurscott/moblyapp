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
  | 'IDENTITY_REQUIRED'
  | 'CONFLICT'
  | 'MAINTENANCE'
  // Remote control. The app branches on these to disable a control, show the
  // admin's own French sentence, sign the user out, or force an update.
  | 'FEATURE_DISABLED'
  | 'USER_RESTRICTED'
  | 'ACCOUNT_SUSPENDED'
  | 'ACCOUNT_LOCKED'
  | 'THREAD_FROZEN'
  | 'CONTENT_BLOCKED'
  | 'FORCE_UPDATE'
  | 'ROLE_REQUIRED'
  | 'ADMIN_IP_BLOCKED'
  | 'CONFIRMATION_REQUIRED'
  | 'LIMIT_REACHED'
  | 'INTERNAL';

export class ApiError extends Error {
  status: number;
  code: ErrorCode;
  /**
   * Extra fields merged into the JSON body. Used to carry the detail the app
   * needs to act on an error rather than merely display it — when a
   * restriction expires, which store URL to open on a forced update.
   */
  extra?: Record<string, unknown>;

  constructor(
    status: number,
    message: string,
    code: ErrorCode = 'INTERNAL',
    extra?: Record<string, unknown>
  ) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}
