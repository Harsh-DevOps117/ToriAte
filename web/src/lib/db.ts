import { Pool } from 'pg';

const g = globalThis as unknown as { boardPool?: Pool };

// Connection: DATABASE_URL, else the standard PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD variables
// (docker-compose.yml points them at the bot's database). DATABASE_SSL: as the bot's BOT_PG_SSL
// (empty or "disable" = off; anything else = TLS with certificate checks).
function makePool() {
  const ssl = process.env.DATABASE_SSL || '';
  return new Pool({
    connectionString: process.env.DATABASE_URL || undefined,
    max: 5,
    ssl: ssl && ssl !== 'disable' ? true : undefined,
  });
}

export const pool = (g.boardPool ??= makePool());

// The board only reads: every query runs in a read-only transaction, so no bug here can change the
// bot's data, whichever credentials the connection carries.
export async function rows<T>(sql: string, params: unknown[] = []): Promise<T[]> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN READ ONLY');
    await c.query("SET LOCAL statement_timeout = '5s'");
    const r = await c.query(sql, params);
    await c.query('COMMIT');
    return r.rows as T[];
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}
