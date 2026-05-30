# ============================================================
# pg_submit.py — 向 PostgreSQL 任务队列提交任务
# 本地 WSL 使用: python pg_submit.py "SQL" --type sql
# ============================================================

import sys
import argparse
import psycopg2
from datetime import datetime

PG_CONFIG = {
    "host": "your.pg.host",
    "port": 5432,
    "database": "your_db",
    "user": "your_user",
    "password": "your_password",
}
TABLE_NAME = "vic.ai_task"


def ensure_table(conn):
    """自动建表（如果不存在）"""
    with conn.cursor() as cur:
        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS {TABLE_NAME} (
                id SERIAL PRIMARY KEY,
                task_type VARCHAR(20) NOT NULL DEFAULT 'pyspark',
                code TEXT NOT NULL,
                status VARCHAR(20) NOT NULL DEFAULT 'pending',
                created_at TIMESTAMP DEFAULT now(),
                done_at TIMESTAMP,
                result TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_ai_task_status ON {TABLE_NAME}(status, created_at);
        """)
        conn.commit()


def submit(conn, code, task_type="pyspark"):
    with conn.cursor() as cur:
        cur.execute(
            f"INSERT INTO {TABLE_NAME} (task_type, code) VALUES (%s, %s) RETURNING id",
            (task_type, code),
        )
        task_id = cur.fetchone()[0]
        conn.commit()
        return task_id


def main():
    parser = argparse.ArgumentParser(description="Submit task to PG queue")
    parser.add_argument("code", nargs="?", help="SQL or PySpark code (or - to read from stdin)")
    parser.add_argument("--type", default="pyspark", choices=["sql", "pyspark"])
    parser.add_argument("--file", help="Read code from file")
    parser.add_argument("--status", action="store_true", help="Show recent task status")
    args = parser.parse_args()

    conn = psycopg2.connect(**PG_CONFIG)
    ensure_table(conn)

    if args.status:
        with conn.cursor() as cur:
            cur.execute(
                f"SELECT id, task_type, status, created_at, done_at, LEFT(result,100) "
                f"FROM {TABLE_NAME} ORDER BY created_at DESC LIMIT 10"
            )
            for row in cur.fetchall():
                print(f"  #{row[0]} [{row[1]}] {row[2]:10s} {str(row[3])[:19]} → {row[5] or '...'}")
        conn.close()
        return

    code = args.code
    if args.file:
        with open(args.file, "r", encoding="utf-8") as f:
            code = f.read()
    elif code == "-" or code is None:
        code = sys.stdin.read()

    if not code or not code.strip():
        print("Error: no code provided")
        sys.exit(1)

    task_id = submit(conn, code, args.type)
    print(f"Task #{task_id} submitted ({args.type}, {len(code)} chars)")
    conn.close()


if __name__ == "__main__":
    main()
