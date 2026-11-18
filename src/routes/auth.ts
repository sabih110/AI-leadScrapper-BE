import { Router, type Request, type Response } from 'express'
import rateLimit from 'express-rate-limit'
import { z } from 'zod'
import * as auth from '../auth/service.js'
import { requireAuth } from '../auth/middleware.js'
import { REFRESH_COOKIE, refreshCookieOptions, verifyAccessToken } from '../auth/tokens.js'
import { config } from '../config.js'
import { HttpError, readCookie } from '../lib/http.js'

const email = z.string().trim().toLowerCase().pipe(z.email({ message: 'Enter a valid email address' }))
// argon2 handles long inputs, but cap it to stop hash-flooding with huge bodies.
const password = z.string().min(8, 'Passwords are at least 8 characters').max(200, 'That password is too long')

const loginSchema = z.object({ email, password })
const registerSchema = z.object({
  name: z.string().trim().min(2, 'Enter your name').max(120),
  email,
  password,
  workspace: z.string().trim().min(2, 'Name your first workspace').max(120),
})

// Brute-force protection on credential endpoints.
const credentialLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: config.NODE_ENV === 'test' ? 1000 : 20,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { message: 'Too many attempts. Please wait a few minutes and try again.', code: 'rate_limited' },
})

const meta = (req: Request) => ({ userAgent: req.get('user-agent'), ip: req.ip })
const setRefreshCookie = (res: Response, token: string) => res.cookie(REFRESH_COOKIE, token, refreshCookieOptions())
const clearRefreshCookie = (res: Response) => {
  const { maxAge: _maxAge, ...opts } = refreshCookieOptions()
  res.clearCookie(REFRESH_COOKIE, opts)
}

export const authRouter = Router()

/** POST /api/auth/register → { token, user, workspaces } + refresh cookie */
authRouter.post('/register', credentialLimiter, async (req, res) => {
  const body = registerSchema.parse(req.body)
  const { refreshToken, ...result } = await auth.register(body, meta(req))
  setRefreshCookie(res, refreshToken)
  res.status(201).json(result)
})

/** POST /api/auth/login → { token, user, workspaces } + refresh cookie */
authRouter.post('/login', credentialLimiter, async (req, res) => {
  const body = loginSchema.parse(req.body)
  const { refreshToken, ...result } = await auth.login(body.email, body.password, meta(req))
  setRefreshCookie(res, refreshToken)
  res.json(result)
})

/** POST /api/auth/refresh → { token }, rotating the refresh cookie */
authRouter.post('/refresh', async (req, res) => {
  const current = readCookie(req.headers.cookie, REFRESH_COOKIE)
  if (!current) throw new HttpError(401, 'Your session has ended. Please sign in again.', 'session_expired')
  try {
    const { token, refreshToken } = await auth.refresh(current)
    setRefreshCookie(res, refreshToken)
    res.json({ token })
  } catch (err) {
    clearRefreshCookie(res)
    throw err
  }
})

/** POST /api/auth/logout → 204. Revokes the session; works even with an expired access token. */
authRouter.post('/logout', async (req, res) => {
  const refreshToken = readCookie(req.headers.cookie, REFRESH_COOKIE)
  let sid: string | undefined
  const header = req.headers.authorization
  if (header?.startsWith('Bearer ')) {
    try {
      sid = verifyAccessToken(header.slice(7)).sid
    } catch {
      /* expired or invalid: fall back to the cookie */
    }
  }
  await auth.revokeSession({ sid, refreshToken })
  clearRefreshCookie(res)
  res.status(204).end()
})

/** GET /api/auth/me → { user, workspaces } */
authRouter.get('/me', requireAuth, async (req, res) => {
  res.json(await auth.me(req.auth!.userId))
})
