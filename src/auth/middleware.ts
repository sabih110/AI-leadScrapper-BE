import type { RequestHandler } from 'express'
import { pool } from '../db/pool.js'
import { HttpError } from '../lib/http.js'
import type { Role } from './service.js'
import { verifyAccessToken } from './tokens.js'

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      auth?: { userId: string; sessionId: string }
      workspace?: { id: string; role: Role }
    }
  }
}

const EXPIRED = () => new HttpError(401, 'Your session has ended. Please sign in again.', 'unauthorized')

/**
 * Requires a valid Bearer access token whose session is still active.
 * The session check makes sign-out take effect immediately instead of when the JWT expires.
 */
export const requireAuth: RequestHandler = async (req, _res, next) => {
  const header = req.headers.authorization
  if (!header?.startsWith('Bearer ')) throw EXPIRED()
  let claims
  try {
    claims = verifyAccessToken(header.slice(7))
  } catch {
    throw EXPIRED()
  }
  const { rowCount } = await pool.query(
    `SELECT 1 FROM auth_sessions s JOIN users u ON u.id = s.user_id
      WHERE s.id = $1 AND s.user_id = $2 AND s.revoked_at IS NULL AND s.expires_at > now() AND u.disabled_at IS NULL`,
    [claims.sid, claims.sub],
  )
  if (!rowCount) throw EXPIRED()
  req.auth = { userId: claims.sub, sessionId: claims.sid }
  next()
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** Resolves X-Workspace-Id and checks the signed-in user is a member. Use after requireAuth. */
export const requireWorkspace: RequestHandler = async (req, _res, next) => {
  const id = req.header('x-workspace-id')
  if (!id || !UUID.test(id)) throw new HttpError(400, 'Choose a workspace first.', 'workspace_required')
  const { rows } = await pool.query<{ role: Role }>(
    `SELECT m.role FROM workspace_members m JOIN workspaces w ON w.id = m.workspace_id
      WHERE m.workspace_id = $1 AND m.user_id = $2 AND w.archived_at IS NULL`,
    [id, req.auth!.userId],
  )
  // 404 rather than 403 so workspace ids can't be probed.
  if (!rows[0]) throw new HttpError(404, 'Workspace not found.', 'workspace_not_found')
  req.workspace = { id, role: rows[0].role }
  next()
}

const RANK: Record<Role, number> = { viewer: 0, analyst: 1, admin: 2, owner: 3 }

/** Requires at least the given role in the current workspace. Use after requireWorkspace. */
export const requireRole =
  (min: Role): RequestHandler =>
  (req, _res, next) => {
    if (RANK[req.workspace!.role] < RANK[min]) throw new HttpError(403, 'You don’t have permission to do that in this workspace.', 'forbidden')
    next()
  }
