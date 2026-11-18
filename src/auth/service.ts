import argon2 from 'argon2'
import type pg from 'pg'
import { config } from '../config.js'
import { pool, tx } from '../db/pool.js'
import { HttpError } from '../lib/http.js'
import { hashToken, newRefreshToken, signAccessToken } from './tokens.js'

export type Role = 'owner' | 'admin' | 'analyst' | 'viewer'

/** Shapes match the frontend's SessionUser and Workspace types. */
export interface SessionUser {
  id: string
  name: string
  email: string
  role: Role
}
export interface WorkspaceDto {
  id: string
  name: string
  client: string | null
  plan: 'Starter' | 'Agency' | 'Agency Pro'
}
export interface AuthResult {
  token: string
  refreshToken: string
  user: SessionUser
  workspaces: WorkspaceDto[]
}

interface SessionMeta {
  userAgent?: string
  ip?: string
}

// Verified against when the email is unknown, so response time doesn't reveal which emails exist.
const dummyHash = argon2.hash('leadforge-timing-equaliser')

const INVALID_LOGIN = new HttpError(401, 'That email and password don’t match. Please try again.', 'invalid_credentials')

type Db = pg.Pool | pg.PoolClient

async function loadWorkspaces(db: Db, userId: string) {
  const { rows } = await db.query<WorkspaceDto & { role: Role }>(
    `SELECT w.id, w.name, w.client, w.plan, m.role
       FROM workspace_members m
       JOIN workspaces w ON w.id = m.workspace_id
      WHERE m.user_id = $1 AND w.archived_at IS NULL
      ORDER BY m.joined_at, w.name`,
    [userId],
  )
  return rows
}

async function buildSessionUser(db: Db, u: { id: string; name: string; email: string }) {
  const ws = await loadWorkspaces(db, u.id)
  const user: SessionUser = { id: u.id, name: u.name, email: u.email, role: ws[0]?.role ?? 'viewer' }
  const workspaces = ws.map(({ id, name, client, plan }) => ({ id, name, client, plan }))
  return { user, workspaces }
}

async function createSession(db: Db, userId: string, meta: SessionMeta) {
  const refreshToken = newRefreshToken()
  const { rows } = await db.query<{ id: string }>(
    `INSERT INTO auth_sessions (user_id, token_hash, user_agent, ip, expires_at)
     VALUES ($1, $2, $3, $4, now() + make_interval(days => $5))
     RETURNING id`,
    [userId, hashToken(refreshToken), meta.userAgent?.slice(0, 500) ?? null, meta.ip ?? null, config.REFRESH_TOKEN_TTL_DAYS],
  )
  const sid = rows[0]!.id
  return { token: signAccessToken({ sub: userId, sid }), refreshToken }
}

export async function register(
  p: { name: string; email: string; password: string; workspace: string },
  meta: SessionMeta,
): Promise<AuthResult> {
  const passwordHash = await argon2.hash(p.password, { type: argon2.argon2id })
  try {
    return await tx(async (db) => {
      const { rows } = await db.query<{ id: string; name: string; email: string }>(
        `INSERT INTO users (name, email, password_hash) VALUES ($1, $2, $3) RETURNING id, name, email`,
        [p.name, p.email, passwordHash],
      )
      const u = rows[0]!
      const ws = await db.query<{ id: string }>(
        `INSERT INTO workspaces (name, created_by) VALUES ($1, $2) RETURNING id`,
        [p.workspace, u.id],
      )
      await db.query(`INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'owner')`, [ws.rows[0]!.id, u.id])
      const session = await createSession(db, u.id, meta)
      return { ...session, ...(await buildSessionUser(db, u)) }
    })
  } catch (err) {
    if ((err as { code?: string }).code === '23505') {
      throw new HttpError(409, 'An account with this email already exists. Try signing in instead.', 'email_taken')
    }
    throw err
  }
}

export async function login(email: string, password: string, meta: SessionMeta): Promise<AuthResult> {
  const { rows } = await pool.query<{ id: string; name: string; email: string; password_hash: string; disabled_at: Date | null }>(
    `SELECT id, name, email, password_hash, disabled_at FROM users WHERE email = $1`,
    [email],
  )
  const u = rows[0]
  if (!u) {
    await argon2.verify(await dummyHash, password).catch(() => false)
    throw INVALID_LOGIN
  }
  if (!(await argon2.verify(u.password_hash, password))) throw INVALID_LOGIN
  if (u.disabled_at) throw new HttpError(403, 'This account has been turned off. Please contact your workspace owner.', 'account_disabled')

  if (argon2.needsRehash(u.password_hash)) {
    const fresh = await argon2.hash(password, { type: argon2.argon2id })
    await pool.query(`UPDATE users SET password_hash = $2 WHERE id = $1`, [u.id, fresh])
  }
  await pool.query(`UPDATE users SET last_active_at = now() WHERE id = $1`, [u.id])

  const session = await createSession(pool, u.id, meta)
  return { ...session, ...(await buildSessionUser(pool, u)) }
}

/** Exchanges a valid refresh token for a new access token, rotating the refresh token. */
export async function refresh(refreshToken: string): Promise<{ token: string; refreshToken: string }> {
  const next = newRefreshToken()
  const { rows } = await pool.query<{ id: string; user_id: string }>(
    `UPDATE auth_sessions s
        SET token_hash = $2, last_used_at = now()
       FROM users u
      WHERE s.token_hash = $1
        AND s.revoked_at IS NULL
        AND s.expires_at > now()
        AND u.id = s.user_id
        AND u.disabled_at IS NULL
      RETURNING s.id, s.user_id`,
    [hashToken(refreshToken), hashToken(next)],
  )
  const s = rows[0]
  if (!s) throw new HttpError(401, 'Your session has ended. Please sign in again.', 'session_expired')
  return { token: signAccessToken({ sub: s.user_id, sid: s.id }), refreshToken: next }
}

export async function revokeSession(by: { sid?: string; refreshToken?: string }) {
  if (by.sid) await pool.query(`UPDATE auth_sessions SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL`, [by.sid])
  if (by.refreshToken) {
    await pool.query(`UPDATE auth_sessions SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL`, [hashToken(by.refreshToken)])
  }
}

export async function me(userId: string) {
  const { rows } = await pool.query<{ id: string; name: string; email: string }>(`SELECT id, name, email FROM users WHERE id = $1`, [userId])
  if (!rows[0]) throw new HttpError(401, 'Your session has ended. Please sign in again.', 'session_expired')
  return buildSessionUser(pool, rows[0])
}

export { loadWorkspaces }
