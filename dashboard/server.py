#!/usr/bin/env python3
"""
Local Dev Dashboard Server
A real-time dashboard for monitoring local development services and logs.
"""

import os
import json
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path
from flask import Flask, render_template, jsonify, Response
from flask_cors import CORS
import yaml

app = Flask(__name__, template_folder='templates', static_folder='static')
CORS(app)

BASE_DIR = Path(__file__).parent.parent
LOGS_DIR = BASE_DIR / 'logs'
CONFIG_FILE = BASE_DIR / 'repos_docker_files' / 'config.yaml'
PROGRESS_FILE = LOGS_DIR / 'progress.json'
METRICS_FILE = LOGS_DIR / 'run_metrics.json'

# Global state for build progress
build_state = {
    'phase': 'idle',
    'phase_number': 0,
    'message': 'Waiting to start...',
    'services': {},
    'start_time': None,
    'logs': []
}

def load_config():
    """Load service configuration from config.yaml"""
    try:
        with open(CONFIG_FILE, 'r') as f:
            return yaml.safe_load(f)
    except Exception as e:
        return {'services': {}}

def get_docker_containers():
    """Get status of all docker containers"""
    try:
        result = subprocess.run(
            ['docker', 'ps', '-a', '--format', '{{.Names}}\t{{.Status}}\t{{.Ports}}'],
            capture_output=True, text=True, timeout=10
        )
        containers = {}
        for line in result.stdout.strip().split('\n'):
            if line:
                parts = line.split('\t')
                name = parts[0]
                status = parts[1] if len(parts) > 1 else 'unknown'
                ports = parts[2] if len(parts) > 2 else ''
                containers[name] = {
                    'status': status,
                    'ports': ports,
                    'running': 'Up' in status
                }
        return containers
    except Exception as e:
        return {}

def get_docker_logs(service_name, lines=100):
    """Get recent logs from a docker container"""
    try:
        result = subprocess.run(
            ['docker', 'logs', '--tail', str(lines), service_name],
            capture_output=True, text=True, timeout=10
        )
        logs = result.stdout + result.stderr
        return logs.split('\n')
    except Exception as e:
        return [f"Error getting logs: {str(e)}"]

def read_build_log(lines=200):
    """Read recent lines from build_output.log"""
    log_file = LOGS_DIR / 'build_output.log'
    try:
        if log_file.exists():
            with open(log_file, 'r') as f:
                all_lines = f.readlines()
                return [line.rstrip() for line in all_lines[-lines:]]
        return []
    except Exception as e:
        return [f"Error reading build log: {str(e)}"]

def get_metrics():
    """Get run metrics from logs/run_metrics.json"""
    try:
        if METRICS_FILE.exists():
            with open(METRICS_FILE, 'r') as f:
                return json.load(f)
    except:
        pass
    return {'runs': []}

def get_progress():
    """Get current build progress from logs/progress.json"""
    try:
        if PROGRESS_FILE.exists():
            with open(PROGRESS_FILE, 'r') as f:
                return json.load(f)
    except:
        pass
    return {
        'run_id': '',
        'start_time': '',
        'current_phase': 0,
        'phases': {},
        'services': [],
        'namespace': '',
        'completed': False
    }

def get_eta_for_operation(metrics, phase_name, op_name):
    """Calculate ETA for an operation based on historical metrics"""
    try:
        runs = metrics.get('runs', [])[-30:]  # Last 30 runs
        if not runs:
            return 0

        key = f"{phase_name}:{op_name}"
        times = []
        for run in runs:
            ops = run.get('operations', {})
            if key in ops:
                times.append(ops[key])

        if times:
            return sum(times) // len(times)
    except:
        pass
    return 0

def parse_build_progress():
    """Parse build_output.log to determine current build state"""
    log_file = LOGS_DIR / 'build_output.log'
    state = {
        'phase': 'unknown',
        'phase_number': 0,
        'services_building': [],
        'services_done': [],
        'errors': []
    }

    try:
        if log_file.exists():
            with open(log_file, 'r') as f:
                content = f.read()

            # Parse phases
            if 'Phase 5' in content or 'Emulator' in content:
                state['phase'] = 'Starting Emulators'
                state['phase_number'] = 5
            elif 'Phase 4' in content or 'Starting containers' in content:
                state['phase'] = 'Starting Containers'
                state['phase_number'] = 4
            elif 'Phase 3' in content or 'Building' in content:
                state['phase'] = 'Building Containers'
                state['phase_number'] = 3
            elif 'Phase 2' in content or 'Docker Configuration' in content:
                state['phase'] = 'Docker Configuration'
                state['phase_number'] = 2
            elif 'Phase 1' in content or 'Repository' in content:
                state['phase'] = 'Repository Setup'
                state['phase_number'] = 1

    except Exception as e:
        state['errors'].append(str(e))

    return state

@app.route('/')
def index():
    """Serve the main dashboard page"""
    return render_template('index.html')

@app.route('/api/status')
def api_status():
    """Get current status of all services"""
    config = load_config()
    containers = get_docker_containers()
    build_progress = parse_build_progress()

    services = {}
    for name, svc in config.get('services', {}).items():
        container_info = containers.get(name, {})
        services[name] = {
            'name': name,
            'type': svc.get('type', 'unknown'),
            'port': svc.get('port', ''),
            'running': container_info.get('running', False),
            'status': container_info.get('status', 'not started'),
            'ports': container_info.get('ports', '')
        }

    # Add workers and other containers
    for container_name, info in containers.items():
        if container_name not in services:
            services[container_name] = {
                'name': container_name,
                'type': 'container',
                'port': '',
                'running': info.get('running', False),
                'status': info.get('status', 'unknown'),
                'ports': info.get('ports', '')
            }

    return jsonify({
        'services': services,
        'build_progress': build_progress,
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/logs/<service_name>')
def api_service_logs(service_name):
    """Get logs for a specific service"""
    logs = get_docker_logs(service_name)
    return jsonify({
        'service': service_name,
        'logs': logs,
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/build-logs')
def api_build_logs():
    """Get build output logs"""
    logs = read_build_log(500)
    return jsonify({
        'logs': logs,
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/metrics')
def api_metrics():
    """Get performance metrics"""
    metrics = get_metrics()
    return jsonify(metrics)

@app.route('/api/progress')
def api_progress():
    """Get current build progress"""
    progress = get_progress()
    return jsonify(progress)

@app.route('/api/progress/stream')
def stream_progress():
    """Stream progress updates in real-time"""
    def generate():
        last_run_id = None
        last_mtime = 0

        while True:
            try:
                if PROGRESS_FILE.exists():
                    current_mtime = PROGRESS_FILE.stat().st_mtime
                    if current_mtime != last_mtime:
                        progress = get_progress()
                        # Check if this is a new run
                        if progress.get('run_id') != last_run_id:
                            last_run_id = progress.get('run_id')
                            yield f"data: {json.dumps({'type': 'new_run', 'data': progress})}\n\n"
                        else:
                            yield f"data: {json.dumps({'type': 'update', 'data': progress})}\n\n"
                        last_mtime = current_mtime
            except Exception as e:
                yield f"data: {json.dumps({'type': 'error', 'error': str(e)})}\n\n"

            time.sleep(0.3)  # Check every 300ms for responsive updates

    return Response(generate(), mimetype='text/event-stream')

@app.route('/api/logs/stream/<service_name>')
def stream_logs(service_name):
    """Stream logs from a service in real-time"""
    def generate():
        process = subprocess.Popen(
            ['docker', 'logs', '-f', '--tail', '50', service_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        try:
            for line in iter(process.stdout.readline, ''):
                yield f"data: {json.dumps({'log': line.rstrip()})}\n\n"
        finally:
            process.kill()

    return Response(generate(), mimetype='text/event-stream')

@app.route('/api/build-logs/stream')
def stream_build_logs():
    """Stream build logs in real-time"""
    def generate():
        log_file = LOGS_DIR / 'build_output.log'
        last_size = 0

        while True:
            try:
                if log_file.exists():
                    current_size = log_file.stat().st_size
                    if current_size > last_size:
                        with open(log_file, 'r') as f:
                            f.seek(last_size)
                            new_content = f.read()
                            for line in new_content.split('\n'):
                                if line.strip():
                                    yield f"data: {json.dumps({'log': line})}\n\n"
                        last_size = current_size
            except Exception as e:
                yield f"data: {json.dumps({'error': str(e)})}\n\n"

            time.sleep(0.5)

    return Response(generate(), mimetype='text/event-stream')

@app.route('/api/all-logs/stream')
def stream_all_logs():
    """Stream logs from all running containers"""
    def generate():
        processes = {}

        def start_container_stream(container_name):
            return subprocess.Popen(
                ['docker', 'logs', '-f', '--tail', '0', container_name],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )

        last_check = 0

        while True:
            # Refresh container list every 5 seconds
            if time.time() - last_check > 5:
                containers = get_docker_containers()
                for name, info in containers.items():
                    if info.get('running') and name not in processes:
                        try:
                            processes[name] = start_container_stream(name)
                        except:
                            pass
                last_check = time.time()

            # Read from all processes
            for name, proc in list(processes.items()):
                try:
                    if proc.poll() is not None:
                        del processes[name]
                        continue

                    import select
                    ready, _, _ = select.select([proc.stdout], [], [], 0.1)
                    if ready:
                        line = proc.stdout.readline()
                        if line:
                            yield f"data: {json.dumps({'service': name, 'log': line.rstrip()})}\n\n"
                except:
                    pass

            time.sleep(0.1)

    return Response(generate(), mimetype='text/event-stream')

@app.route('/api/shutdown', methods=['POST'])
def api_shutdown():
    """Shutdown the dashboard server gracefully"""
    def shutdown_server():
        time.sleep(0.5)  # Give time for response to be sent
        # Kill the dashboard process
        pid_file = LOGS_DIR / 'dashboard.pid'
        if pid_file.exists():
            try:
                pid_file.unlink()
            except:
                pass
        os._exit(0)

    # Start shutdown in background thread
    shutdown_thread = threading.Thread(target=shutdown_server)
    shutdown_thread.daemon = True
    shutdown_thread.start()

    return jsonify({'status': 'shutting_down', 'message': 'Dashboard will close in a moment'})

if __name__ == '__main__':
    print("\n" + "="*60)
    print("  Local Dev Dashboard")
    print("  Open http://localhost:9999 in your browser")
    print("="*60 + "\n")
    app.run(host='0.0.0.0', port=9999, debug=False, threaded=True)
