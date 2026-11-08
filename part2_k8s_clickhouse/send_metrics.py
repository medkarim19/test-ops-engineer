import random
import uuid
from datetime import datetime, timedelta

import requests

URL = "http://127.0.0.1:30123/"

rows = []

for _ in range(10):
    ts = datetime.now() - timedelta(minutes=random.randint(0, 1000))

    rows.append(
        f"{uuid.uuid4().hex[:8]}\t"
        f"{ts:%Y-%m-%d %H:%M:%S}\t"
        f"{random.randint(1, 600)}\t"
        f"{random.randint(0, 1)}"
    )

query = "INSERT INTO metrics.job_metrics (job_id, timestamp, duration_sec, success) FORMAT TabSeparated"

r = requests.post(
    URL,
    params={"query": query},
    data="\n".join(rows) + "\n",
    auth=("root", "root"),
    timeout=30
)

r.raise_for_status()

print("10 rows inserted successfully!")

