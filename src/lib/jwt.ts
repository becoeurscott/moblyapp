import jwt from 'jsonwebtoken';
import { env } from '../config/env';

export interface JwtPayload {
  sub: string; // user id
  phone: string;
  /**
   * Token version, mirroring `User.tokenVersion`. Bumping the column
   * invalidates every access token already issued, which is what makes
   * "forcer la déconnexion" immediate instead of "within 15 minutes".
   *
   * Optional so tokens minted before this claim existed keep working: a
   * missing `tv` reads as 0, which equals the column's default.
   */
  tv?: number;
}

export function signToken(payload: JwtPayload): string {
  return jwt.sign(payload, env.jwtSecret, { expiresIn: env.jwtExpiresIn } as jwt.SignOptions);
}

export function verifyToken(token: string): JwtPayload {
  return jwt.verify(token, env.jwtSecret) as JwtPayload;
}
