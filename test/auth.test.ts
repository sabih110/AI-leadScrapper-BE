/**
 * Integration tests for JWT auth. Needs a migrated database:
 *   DATABASE_URL=... JWT_SECRET=... npm test
 */
import { randomUUID } from 'node:crypto'
import jwt from 'jsonwebtoken'
import request from 'supertest'
import { afterAll, describe, expect, it } from 'vitest'
import { createApp } from '../src/app.js'
import { pool } from '../src/db/pool.js'

const app = createApp()
const email = `user-${randomUUID()}@example.com`
const password = 'correct-horse-battery'

const cookieFrom = (res: request.Response) => {
  const raw = ([] as string[]).concat(res.headers['set-cookie'] ?? [])
  return raw.find((c) => c.startsWith('lf_refresh='))?.split(';')[0]
}

afterAll(async () => {
  await pool.query(`DELETE FROM workspaces WHERE created_by IN (SELECT id FROM users WHERE email LIKE 'user-%@example.com')`)
  await pool.query(`DELETE FROM users WHERE email LIKE 'user-%@example.com'`)
  await pool.end()
})

describe('auth', () => {
  let token = ''
  let cookie = ''
  let workspaceId = ''

  it('registers a user with a workspace and returns a token + httpOnly refresh cookie', async () => {
    const res = await request(app).post('/api/auth/register').send({ name: 'Ada Test', email: email.toUpperCase(), password, workspace: 'Test Agency' })
    expect(res.status).toBe(201)
    expect(res.body.user).toMatchObject({ name: 'Ada Test', email, role: 'owner' })
    expect(res.body.workspaces).toHaveLength(1)
    expect(res.body).not.toHaveProperty('refreshToken')
    const setCookie = ([] as string[]).concat(res.headers['set-cookie'] ?? []).join(';')
    expect(setCookie).toMatch(/HttpOnly/i)
    expect(setCookie).toMatch(/Path=\/api\/auth/i)
    workspaceId = res.body.workspaces[0].id
  })

  it('rejects a duplicate email with 409', async () => {
    const res = await request(app).post('/api/auth/register').send({ name: 'Ada', email, password, workspace: 'Other' })
    expect(res.status).toBe(409)
  })

  it('validates input with a readable message', async () => {
    const res = await request(app).post('/api/auth/login').send({ email: 'nope', password: 'x' })
    expect(res.status).toBe(400)
    expect(res.body.message).toBe('Enter a valid email address')
  })

  it('gives the same 401 for a wrong password and an unknown email', async () => {
    const a = await request(app).post('/api/auth/login').send({ email, password: 'wrong-password' })
    const b = await request(app).post('/api/auth/login').send({ email: `nobody-${randomUUID()}@example.com`, password })
    expect(a.status).toBe(401)
    expect(b.status).toBe(401)
    expect(a.body.message).toBe(b.body.message)
  })

  it('logs in and reaches protected routes with the access token', async () => {
    const res = await request(app).post('/api/auth/login').send({ email, password })
    expect(res.status).toBe(200)
    token = res.body.token
    cookie = cookieFrom(res)!
    expect(cookie).toBeTruthy()

    const me = await request(app).get('/api/auth/me').set('Authorization', `Bearer ${token}`)
    expect(me.status).toBe(200)
    expect(me.body.user.email).toBe(email)

    const team = await request(app).get('/api/team').set('Authorization', `Bearer ${token}`).set('X-Workspace-Id', workspaceId)
    expect(team.status).toBe(200)
    expect(team.body[0]).toMatchObject({ email, role: 'owner', status: 'active' })
  })

  it('rejects missing, tampered and alg=none tokens', async () => {
    expect((await request(app).get('/api/auth/me')).status).toBe(401)
    const tampered = token.slice(0, -2) + (token.endsWith('A') ? 'BB' : 'AA')
    expect((await request(app).get('/api/auth/me').set('Authorization', `Bearer ${tampered}`)).status).toBe(401)
    const claims = jwt.decode(token) as jwt.JwtPayload
    const none = jwt.sign(claims, '', { algorithm: 'none' })
    expect((await request(app).get('/api/auth/me').set('Authorization', `Bearer ${none}`)).status).toBe(401)
  })

  it('hides workspaces the user is not a member of', async () => {
    const res = await request(app).get('/api/team').set('Authorization', `Bearer ${token}`).set('X-Workspace-Id', randomUUID())
    expect(res.status).toBe(404)
  })

  it('refreshes with the cookie and rotates it (old cookie stops working)', async () => {
    const res = await request(app).post('/api/auth/refresh').set('Cookie', cookie)
    expect(res.status).toBe(200)
    expect(res.body.token).toBeTruthy()
    const rotated = cookieFrom(res)!
    expect(rotated).not.toBe(cookie)

    const reuse = await request(app).post('/api/auth/refresh').set('Cookie', cookie)
    expect(reuse.status).toBe(401)

    cookie = rotated
    token = res.body.token
    expect((await request(app).get('/api/auth/me').set('Authorization', `Bearer ${token}`)).status).toBe(200)
  })

  it('logout revokes the session immediately', async () => {
    const out = await request(app).post('/api/auth/logout').set('Authorization', `Bearer ${token}`).set('Cookie', cookie)
    expect(out.status).toBe(204)
    expect((await request(app).get('/api/auth/me').set('Authorization', `Bearer ${token}`)).status).toBe(401)
    expect((await request(app).post('/api/auth/refresh').set('Cookie', cookie)).status).toBe(401)
  })
})
