import { createApp } from './app.js'
import { config } from './config.js'
import { pool } from './db/pool.js'

const server = createApp().listen(config.PORT, () => {
  console.log(`LeadForge API listening on http://localhost:${config.PORT}/api`)
})

const shutdown = () => {
  server.close(() => pool.end().finally(() => process.exit(0)))
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
