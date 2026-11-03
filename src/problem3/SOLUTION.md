# Problem 3: Debugging issues within system

**Note:** I did not run Docker. I found the problems by reading the files. The fixes are not tested. I list the commands I would run to prove each problem.

## Problems found

| # | Problem | What happens |
|---|---|---|
| 1 | nginx sends requests to port `3001`, but the API uses port `3000` | Every `/api/` request fails with 502. The home page `/` still works, so it looks half alive. |
| 2 | When a database query fails, the API does not give the connection back | After 10 errors, there are no free connections. The API freezes. |
| 3 | The API waits forever for a free database connection | Requests hang and never answer. |
| 4 | nginx remembers the old IP address of the API | When the API container restarts, it gets a new IP. nginx keeps using the old one and returns 502. |
| 5 | The API starts before the database is ready, and nothing restarts it | The first requests fail. If the API stops, it stays stopped. |
| 6 | No error handler for the database connection pool | If the database restarts, the API can crash. |
| 7 | The database has no volume | All data is lost when the container is recreated. |
| 8 | `init.sql` is never used (it sets `max_connections = 20`) | It looks like a safety setting, but it does nothing. |
| 9 | The password `postgres` is written in the code | A security risk. Not fixed here (see "Prevent"). |

## How I found them

I read each file and compared the settings:
- nginx says port 3001. `index.js` says `listen(3000)`. They do not match.
- `index.js` calls `db.release()` only if the query works.
- `docker-compose.yml` has `depends_on` only, with no health check, no restart, no volume.
- `init.sql` is not mounted in `docker-compose.yml`.

Commands I would run to confirm:

```bash
curl -i localhost:8080/            # 200 means nginx works
curl -i localhost:8080/api/users   # 502 means the API side is broken
docker compose logs nginx          # "connection refused ... api:3001"
docker compose logs api            # errors and crashes
docker compose exec postgres psql -U postgres -c "select count(*) from pg_stat_activity;"   # too many open connections
docker compose restart api         # then curl again: 502 means nginx has the old IP
```

## Fixes

1. **nginx** (`nginx/conf.d/default.conf`)
   - Port changed from `3001` to `3000`.
   - Added `resolver 127.0.0.11` and a variable, so nginx looks up the API address again each time.
   - Added timeouts, so requests do not hang.
2. **API** (`api/src/index.js`) - only 3 small changes:
   - `pool.query(...)` instead of `connect` + `query` + `release`. It gives the connection back by itself.
   - `connectionTimeoutMillis: 2000`. Stop waiting after 2 seconds.
   - `pool.on("error", ...)`. A database error does not crash the API.
3. **Docker Compose** (`docker-compose.yml`)
   - Health checks for postgres and redis. The API waits until they are ready.
   - `restart: unless-stopped` on every service.
   - A volume `pgdata` for the database.
4. Removed `postgres/init.sql` because it did nothing.

## Alerts I would add

- The website or `/api/users` fails 2 times in a row.
- Many 5xx errors from nginx (for example more than 1% for 5 minutes).
- A container restarts again and again.
- The database uses more than 80% of its connections.
- Slow API answers (p95 over 500 ms).
- CPU, memory, or disk is almost full.

## How to prevent this in production

- Before release, a test in CI starts the stack and calls `/` and `/api/users` through nginx.
- Also check the nginx config in CI with `nginx -t`.
- Put passwords in a secret manager, not in the code or in git.
- Pin versions, use a lockfile with `npm ci`, and run the container as a non-root user.
- Run more than one API copy behind a load balancer, and use a managed database with backups.
- Set CPU and memory limits for each container.
