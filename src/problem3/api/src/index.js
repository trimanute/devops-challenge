const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const app = express();

const pool = new Pool({
  host: process.env.DB_HOST,
  user: "postgres",
  password: "postgres",
  database: "postgres",
  port: 5432,
  connectionTimeoutMillis: 2000, // give up after 2 seconds, do not wait forever
});

// Without this, an error on an idle connection (for example the database restarts) crashes the app
pool.on("error", (err) => console.error("postgres pool error", err.message));

const redis = new Redis({ host: process.env.REDIS_HOST, port: 6379 });

app.get("/api/users", async (req, res) => {
  try {
    // pool.query gets a connection and always gives it back, even when the query fails
    const result = await pool.query("SELECT NOW()");

    await redis.set("last_call", Date.now());
    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    console.error(err);
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get("/status", (req, res) => {
  res.json({ status: "ok" });
});

app.listen(3000, () => console.log("API running on 3000"));
