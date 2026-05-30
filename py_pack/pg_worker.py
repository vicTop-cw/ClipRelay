# ============================================================
# pg_worker.py — PostgreSQL 任务队列消费者
# 运行在跳板机上: python pg_worker.py
# 监控 pg_task 表，执行 SQL/代码，结果写入 Share
# ============================================================

import time
import traceback
import sys
import os
from datetime import datetime

try:
    import psycopg2
    import pandas as pd
except ImportError:
    print("请先运行 install_py.bat 安装依赖")
    sys.exit(1)

# ── 配置 ──
PG_CONFIG = {
    "host": "your.pg.host",
    "port": 5432,
    "database": "your_db",
    "user": "your_user",
    "password": "your_password",
}
SHARE_DIR = r"\\allonas.allobank.local\bdap_data\bdap\nabops_victorchen\Share"
POLL_INTERVAL = 3  # 秒
TABLE_NAME = "vic.ai_task"

# ── 日志 ──
def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


# ── 执行 SQL ──
def exec_sql(task_id, code):
    from pyspark.sql import SparkSession
    spark = SparkSession.builder.appName(f"ai_task_{task_id}").getOrCreate()
    try:
        df = spark.sql(code)
        filepath = os.path.join(SHARE_DIR, f"task_{task_id}.xlsx")
        df.to_excel(filepath, index=False)
        return f"OK: {df.count()} rows → {filepath}"
    except Exception as e:
        err_file = os.path.join(SHARE_DIR, f"task_{task_id}_err.txt")
        with open(err_file, "w", encoding="utf-8") as f:
            f.write(f"{type(e).__name__}: {e}\n{traceback.format_exc()}")
        return f"ERR: {e}"


# ── 执行 PySpark 代码 ──
def exec_pyspark(task_id, code):
    try:
        loc = {}
        exec(code, loc)
        if "df" in loc:
            filepath = os.path.join(SHARE_DIR, f"task_{task_id}.xlsx")
            loc["df"].to_excel(filepath, index=False)
            return f"OK: {loc['df'].count()} rows → {filepath}"
        else:
            msg = loc.get("result", "executed - no df produced")
            filepath = os.path.join(SHARE_DIR, f"task_{task_id}.txt")
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(str(msg))
            return f"OK: text → {filepath}"
    except Exception as e:
        err_file = os.path.join(SHARE_DIR, f"task_{task_id}_err.txt")
        with open(err_file, "w", encoding="utf-8") as f:
            f.write(f"{type(e).__name__}: {e}\n{traceback.format_exc()}")
        return f"ERR: {e}"


# ── 更新任务状态 ──
def update_status(conn, task_id, result):
    with conn.cursor() as cur:
        cur.execute(
            f"UPDATE {TABLE_NAME} SET status='done', result=%s, done_at=now() WHERE id=%s",
            (result[:4000], task_id),  # PG TEXT 字段限制
        )
        conn.commit()


# ── 主循环 ──
def main():
    log("pg_worker started")
    log(f"Polling {TABLE_NAME} every {POLL_INTERVAL}s")
    
    while True:
        try:
            conn = psycopg2.connect(**PG_CONFIG)
            with conn.cursor() as cur:
                # 取最早的一条 pending 任务
                cur.execute(
                    f"SELECT id, task_type, code FROM {TABLE_NAME} "
                    "WHERE status='pending' ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED"
                )
                row = cur.fetchone()
                
                if row:
                    task_id, task_type, code = row
                    log(f"Task #{task_id} ({task_type})")
                    update_status(conn, task_id, "running")
                    
                    if task_type == "sql":
                        result = exec_sql(task_id, code)
                    else:
                        result = exec_pyspark(task_id, code)
                    
                    update_status(conn, task_id, result)
                    log(f"Task #{task_id}: {result}")
            
            conn.close()
        except Exception as e:
            log(f"DB error: {e}")
            try:
                conn.close()
            except:
                pass
        
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
