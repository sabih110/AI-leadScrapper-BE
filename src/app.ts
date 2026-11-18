import cors from 'cors'
import express from 'express'
import helmet from 'helmet'
import { pinoHttp } from 'pino-http'
import { config } from './config.js'
import { errorHandler } from './lib/http.js'
import { authRouter } from './routes/auth.js'
import { workspaceRouter } from './routes/workspaces.js'

export function createApp() {
  const app = express()
  app.disable('x-powered-by')
  app.set('trust proxy', 1) // correct client IP for rate limiting behind one proxy

  app.use(helmet())
  app.use(
    cors({
      origin: config.corsOrigins,
      credentials: true, // allow the refresh cookie
      allowedHeaders: ['Content-Type', 'Authorization', 'X-Workspace-Id'],
    }),
  )
  app.use(express.json({ limit: '1mb' }))
  if (config.NODE_ENV !== 'test') {
    app.use(
      pinoHttp({
        redact: ['req.headers.authorization', 'req.headers.cookie', 'res.headers["set-cookie"]'],
        transport: config.isProd ? undefined : { target: 'pino-pretty' },
      }),
    )
  }

  app.get('/api/health', (_req, res) => res.json({ ok: true }))
  app.use('/api/auth', authRouter)
  app.use('/api', workspaceRouter)

  app.use('/api', (_req, res) => res.status(404).json({ message: 'Not found', code: 'not_found' }))
  app.use(errorHandler)
  return app
}
