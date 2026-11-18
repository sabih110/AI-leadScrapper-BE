import pg from 'pg'
import { config } from '../config.js'

export const pool = new pg.Pool({ connectionString: config.DATABASE_URL, max: 10 })

/** Runs fn inside a transaction on one client; rolls back on any error. */
export async function tx<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    const result = await fn(client)
    await client.query('COMMIT')
    return result
  } catch (err) {
    await client.query('ROLLBACK')
    throw err
  } finally {
    client.release()
  }
}
