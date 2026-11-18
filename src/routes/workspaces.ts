import { Router } from 'express'
import { loadWorkspaces } from '../auth/service.js'
import { requireAuth, requireWorkspace } from '../auth/middleware.js'
import { pool } from '../db/pool.js'

export const workspaceRouter = Router()

/** GET /api/workspaces — workspaces the signed-in user belongs to. */
workspaceRouter.get('/workspaces', requireAuth, async (req, res) => {
  const rows = await loadWorkspaces(pool, req.auth!.userId)
  res.json(rows.map(({ id, name, client, plan }) => ({ id, name, client, plan })))
})

/** GET /api/team — members and open invitations of the current workspace. */
workspaceRouter.get('/team', requireAuth, requireWorkspace, async (req, res) => {
  const { rows } = await pool.query(
    `SELECT u.id, u.name, u.email, m.role, m.last_active_at AS "lastActive", 'active' AS status
       FROM workspace_members m JOIN users u ON u.id = m.user_id
      WHERE m.workspace_id = $1
     UNION ALL
     SELECT i.id, coalesce(i.name, i.email), i.email, i.role, NULL, 'invited'
       FROM workspace_invitations i
      WHERE i.workspace_id = $1 AND i.accepted_at IS NULL AND i.revoked_at IS NULL AND i.expires_at > now()
      ORDER BY status, name`,
    [req.workspace!.id],
  )
  res.json(rows)
})
