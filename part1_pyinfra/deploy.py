from pathlib import Path
from pyinfra.operations import files, systemd

BASE_DIR = Path(__file__).resolve().parent
REMOTE_DIR = "/opt/metrics-collector"

files.directory(
    name="Create application directory",
    path=REMOTE_DIR,
    present=True,
    _sudo=True,
)

script = files.put(
    name="Copy Python script",
    src=str(BASE_DIR / "metrics_collector.py"),
    dest=f"{REMOTE_DIR}/metrics_collector.py",
    mode="755",
    _sudo=True,
)

unit = files.put(
    name="Copy systemd service",
    src=str(BASE_DIR / "metrics-collector.service"),
    dest="/etc/systemd/system/metrics-collector.service",
    _sudo=True,
)

systemd.service(
    name="Enable and start metrics collector",
    service="metrics-collector",
    running=True,
    enabled=True,
    daemon_reload=unit.changed,                # reload seulement si l'unité a changé
    restarted=script.changed or unit.changed,  # restart seulement si un fichier a changé
    _sudo=True,
)
