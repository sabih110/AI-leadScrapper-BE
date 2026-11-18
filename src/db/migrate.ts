/**
 * Applies pending SQL migrations from ./migrations in filename order.
 * Each file runs in its own transaction and is recorded in schema_migrations
 * with a checksum, so an edited, already-applied migration is reported instead of re-run.
 *
 *   npm run migrate          (reads DATABASE_URL from AI-leadScrapper-BE/.env)
 */
import { createHash } from 'node:crypto'
import { readdir, readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import pg from 'pg'

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), 'migrations')

async function main() {
  const url = process.env.DATABASE_URL
  if (!url) throw new Error('DATABASE_URL is not set (see AI-leadScrapper-BE/.env.example)')

  const client = new pg.Client({ connectionString: url })
  await client.connect()
  try {
    // Only one migrator at a time.
    await client.query('SELECT pg_advisory_lock(hashtext($1))', ['leadforge_migrations'])
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        name       text PRIMARY KEY,
        checksum   text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )`)

    const applied = new Map<string, string>(
      (await client.query<{ name: string; checksum: string }>('SELECT name, checksum FROM schema_migrations'))
        .rows.map((r) => [r.name, r.checksum]),
    )
    const files = (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort()

    let ran = 0
    for (const file of files) {
      const sql = await readFile(path.join(dir, file), 'utf8')
      const checksum = createHash('sha256').update(sql).digest('hex')
      const previous = applied.get(file)
      if (previous) {
        if (previous !== checksum) {
          console.warn(`! ${file} changed after it was applied — add a new migration instead of editing it`)
        }
        continue
      }
      process.stdout.write(`→ ${file} … `)
      await client.query('BEGIN')
      try {
        await client.query(sql)
        await client.query('INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)', [file, checksum])
        await client.query('COMMIT')
        console.log('done')
        ran++
      } catch (err) {
        await client.query('ROLLBACK')
        console.log('failed')
        throw err
      }
    }
    console.log(ran ? `Applied ${ran} migration(s).` : 'Database is up to date.')
  } finally {
    await client.end()
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err)
  process.exit(1)
})
