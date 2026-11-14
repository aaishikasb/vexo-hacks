#!/usr/bin/env python3
"""Run the installed Debug app's real glasses-camera check; no band or microphone.

Only SDK state metadata is copied back. The photo remains in app memory.
"""
import json
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 scripts/check_camera.py IPHONE_DEVICE_ID")
    device = sys.argv[1]
    run_id = str(uuid.uuid4())
    subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", device,
                    "--terminate-existing", "--timeout", "15", "com.aaishika.voca", "--",
                    "--camera-check", run_id], check=True, stdout=subprocess.DEVNULL)
    deadline = time.monotonic() + 45
    with tempfile.TemporaryDirectory(prefix="voca-camera-check-") as temporary:
        target = Path(temporary) / "result.json"
        while time.monotonic() < deadline:
            target.unlink(missing_ok=True)
            result = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", device,
                "--domain-type", "appDataContainer", "--domain-identifier", "com.aaishika.voca",
                "--source", "Documents/camera-check.json", "--destination", str(target), "--timeout", "5"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode == 0 and target.exists():
                record = json.loads(target.read_text())
                if record.get("runID") == run_id and record.get("outcome") in ("passed", "failed"):
                    print(json.dumps(record, indent=2))
                    if record["outcome"] == "passed":
                        assert record["photoBytes"] > 0, "A passing check requires an actual photo"
                        return
                    raise SystemExit(1)
            time.sleep(1)
    raise SystemExit("Camera check produced no terminal result within 45 seconds; verify the phone is unlocked and the Debug app launches.")


if __name__ == "__main__":
    main()
