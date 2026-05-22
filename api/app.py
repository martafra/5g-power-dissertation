#!/usr/bin/env python3
# Flask API for the 5G power consumption platform.
# Exposes endpoints for topology scaling, autoscaling, load generation and power metrics.

import subprocess
import threading
import json
import os
import glob
from datetime import datetime
from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

SCRIPTS_DIR = os.path.expanduser("~/5g-power-dissertation/scripts")
LOGS_DIR = os.path.expanduser("~/5g-power-dissertation/docs/logs")
SCAPHANDRE_URL = "http://10.53.1.11:8080/metrics"

# global handles for long-running background processes
autoscale_process = None
load_process = None


def run_script(script, args=[]):
    cmd = ["bash", os.path.join(SCRIPTS_DIR, script)] + args
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return result.returncode, result.stdout, result.stderr


def get_active_containers():
    result = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}} {{.Status}}"],
        capture_output=True, text=True
    )
    containers = {}
    for line in result.stdout.strip().split("\n"):
        if not line:
            continue
        parts = line.split(" ", 1)
        if len(parts) == 2:
            containers[parts[0]] = parts[1]
    return containers


def get_current_topology():
    containers = get_active_containers()
    cu_count = sum(1 for k in containers if k.startswith("srsran_cu_cp_"))
    du_count = sum(1 for k in containers if k.startswith("srsran_du_"))
    du_per_cu = du_count // cu_count if cu_count > 0 else 0
    return {
        "cu_count": cu_count,
        "du_count": du_count,
        "du_per_cu": du_per_cu,
        "label": f"{cu_count}CU-{du_count}DU" if cu_count > 0 else "none"
    }


def get_power():
    # query Scaphandre and sum power for srsRAN processes only
    import urllib.request
    try:
        with urllib.request.urlopen(SCAPHANDRE_URL, timeout=3) as r:
            metrics = r.read().decode()
        total = 0
        for line in metrics.split("\n"):
            if "scaph_process_power_consumption_microwatts" in line and not line.startswith("#"):
                if any(x in line for x in ["srscucp", "srscuup", "srsdu"]):
                    try:
                        val = float(line.split("}")[-1].strip()) / 1e6
                        if val > 0.05:
                            total += val
                    except:
                        pass
        return round(total, 3)
    except:
        return 0.0


DIST_DIR = os.path.join(os.path.dirname(__file__), 'dist')

@app.route('/')
def index():
    return send_from_directory(DIST_DIR, 'index.html')

@app.route('/<path:path>')
def static_files(path):
    if os.path.exists(os.path.join(DIST_DIR, path)):
        return send_from_directory(DIST_DIR, path)
    return send_from_directory(DIST_DIR, 'index.html')

@app.route("/api/status")
def status():
    topology = get_current_topology()
    power = get_power()
    containers = get_active_containers()
    return jsonify({
        "topology": topology,
        "power_W": power,
        "power_per_du_W": round(power / topology["du_count"], 3) if topology["du_count"] > 0 else 0,
        "containers": list(containers.keys()),
        "autoscale_running": autoscale_process is not None and autoscale_process.poll() is None,
        "load_running": load_process is not None and load_process.poll() is None,
        "timestamp": datetime.utcnow().isoformat()
    })


@app.route("/api/scale", methods=["POST"])
def scale():
    # trigger a topology transition in a background thread
    data = request.json or {}
    cu = data.get("cu", 1)
    du = data.get("du", 1)
    warn = data.get("warn_threshold", 80)
    scaledown = data.get("scaledown_threshold", 30)

    def run():
        run_script("scale.sh", [
            "--cu", str(cu),
            "--du", str(du),
            "--warn-threshold", str(warn),
            "--scaledown-threshold", str(scaledown)
        ])

    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    return jsonify({"status": "scaling", "target": f"{cu}CU-{du}DU"})


@app.route("/api/teardown", methods=["POST"])
def teardown():
    data = request.json or {}
    stop_all = data.get("all", False)
    args = ["--all"] if stop_all else []

    def run():
        run_script("teardown.sh", args)

    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    return jsonify({"status": "teardown started", "all": stop_all})


@app.route("/api/autoscale/start", methods=["POST"])
def autoscale_start():
    global autoscale_process
    if autoscale_process and autoscale_process.poll() is None:
        return jsonify({"status": "already running"}), 400

    data = request.json or {}
    args = [
        "--min-cu", str(data.get("min_cu", 1)),
        "--max-cu", str(data.get("max_cu", 3)),
        "--du", str(data.get("du", 1)),
        "--interval", str(data.get("interval", 30)),
        "--consecutive", str(data.get("consecutive", 2)),
        "--cooldown", str(data.get("cooldown", 60)),
        "--high-threshold", str(data.get("high_threshold", 3.0)),
        "--low-threshold", str(data.get("low_threshold", 1.5)),
    ]

    autoscale_process = subprocess.Popen(
        ["bash", os.path.join(SCRIPTS_DIR, "autoscale.sh")] + args
    )
    return jsonify({"status": "autoscale started", "pid": autoscale_process.pid})


@app.route("/api/autoscale/stop", methods=["POST"])
def autoscale_stop():
    global autoscale_process
    if autoscale_process and autoscale_process.poll() is None:
        autoscale_process.terminate()
        return jsonify({"status": "autoscale stopped"})
    return jsonify({"status": "not running"}), 400


@app.route("/api/load/start", methods=["POST"])
def load_start():
    global load_process
    if load_process and load_process.poll() is None:
        return jsonify({"status": "already running"}), 400

    data = request.json or {}
    args = [
        "--sequence", data.get("sequence", "1,16,96,16,1"),
        "--duration", str(data.get("duration", 60)),
        "--cqi", str(data.get("cqi", 15)),
    ]

    load_process = subprocess.Popen(
        ["bash", os.path.join(SCRIPTS_DIR, "load_generator.sh")] + args
    )
    return jsonify({"status": "load generator started", "pid": load_process.pid})


@app.route("/api/load/stop", methods=["POST"])
def load_stop():
    global load_process
    if load_process and load_process.poll() is None:
        load_process.terminate()
        return jsonify({"status": "load generator stopped"})
    return jsonify({"status": "not running"}), 400


@app.route("/api/metrics/history")
def metrics_history():
    # return the last 50 relevant lines from recent scaling logs
    log_files = sorted(glob.glob(f"{LOGS_DIR}/scaling/scale_*.log"))
    events = []
    for f in log_files[-5:]:
        with open(f) as fp:
            for line in fp:
                if any(x in line for x in ["SCALING EVENT", "Transition complete", "Power before", "Power after"]):
                    events.append(line.strip())
    return jsonify({"events": events[-50:]})




@app.route("/api/metrics/breakdown")
def metrics_breakdown():
    # query Scaphandre and return per-container power consumption
    import urllib.request
    try:
        with urllib.request.urlopen(SCAPHANDRE_URL, timeout=3) as r:
            metrics = r.read().decode()
    except:
        return jsonify({"components": {}})

    # map PIDs to container names
    containers = get_active_containers()
    pid_to_name = {}
    for name in containers:
        result = subprocess.run(
            ["docker", "inspect", name, "--format", "{{.State.Pid}}"],
            capture_output=True, text=True
        )
        pid = result.stdout.strip()
        if pid:
            pid_to_name[pid] = name

    breakdown = {}
    for line in metrics.split("\n"):
        if "scaph_process_power_consumption_microwatts" in line and not line.startswith("#"):
            try:
                pid = line.split('pid="')[1].split('"')[0]
                val = float(line.split("}")[-1].strip()) / 1e6
                if pid in pid_to_name and val > 0.01:
                    breakdown[pid_to_name[pid]] = round(val, 3)
            except:
                pass

    return jsonify({"components": breakdown})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
