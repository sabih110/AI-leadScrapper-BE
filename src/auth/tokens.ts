/**
 * Two-token scheme:
 *  - Access token: short-lived HS256 JWT (default 15 min) sent as `Authorization: Bearer`.
 *    Carries the session id (sid) so logout revokes it immediately.
 *  - Refresh token: opaque random value in an httpOnly cookie (default 30 days).
 *    Only its SHA-256 hash is stored (auth_sessions.token_hash); rotated on every use.
 */
import { createHash, randomBytes } from 'node:crypto'
import jwt from 'jsonwebtoken'
import { config } from '../config.js'

const ISSUER = 'leadforge'
const AUDIENCE = 'leadforge-api'

export interface AccessClaims {
  sub: string // user id
  sid: string // auth_sessions.id
}

export function signAccessToken(c: AccessClaims): string {
  return jwt.sign({ sid: c.sid, typ: 'access' }, config.JWT_SECRET, {
    algorithm: 'HS256',
    subject: c.sub,
    issuer: ISSUER,
    audience: AUDIENCE,
    expiresIn: config.ACCESS_TOKEN_TTL_MINUTES * 60,
  })
}

/** Throws on a bad signature, wrong issuer/audience, wrong type, or expiry. */
export function verifyAccessToken(token: string): AccessClaims {
  const p = jwt.verify(token, config.JWT_SECRET, {
    algorithms: ['HS256'], // pinned: never accept "none" or a different algorithm
    issuer: ISSUER,
    audience: AUDIENCE,
  })
  if (typeof p === 'string' || p.typ !== 'access' || typeof p.sub !== 'string' || typeof p.sid !== 'string') {
    throw new Error('Invalid token payload')
  }
  return { sub: p.sub, sid: p.sid }
}

export const newRefreshToken = () => randomBytes(32).toString('base64url')
export const hashToken = (t: string) => createHash('sha256').update(t).digest('hex')

export const REFRESH_COOKIE = 'lf_refresh'

export function refreshCookieOptions() {
  return {
    httpOnly: true,
    secure: config.isProd,
    sameSite: 'lax' as const,
    path: '/api/auth', // only sent to the auth endpoints
    maxAge: config.REFRESH_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000,
  }
}
