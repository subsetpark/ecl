"""Measure public service workloads using a native ReleaseSafe Linux binary.

Run with stdin closed and an outer timeout. Build the binary with
-Doptimize=ReleaseSafe before invoking this host fixture. /proc sampling covers
only the interpreter, not its subprocesses or controlled peer sockets.
"""
import argparse
import json
import os
import pathlib
import platform
import selectors
import socket
import subprocess
import tempfile
import threading
import time

p = argparse.ArgumentParser()
p.add_argument('binary', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--commit', required=True)
p.add_argument('--repetitions', type=int, default=5)
p.add_argument('--workload', choices=('filesystem-directory-resources', 'filesystem-stat', 'filesystem-read', 'filesystem-staging-cleanup', 'network-connections', 'process-duplex'))
a = p.parse_args()
if platform.system() != 'Linux':
    p.error('thread and RSS sampling requires Linux /proc')
if a.repetitions < 1:
    p.error('--repetitions must be positive')
binary = a.binary.resolve()
workloads = {
    'filesystem-directory-resources': (4096, "16 (256 range (pop 'cwd \".\" fs.child-dir) each (port.close 0) each pop) times 4096"),
    'filesystem-stat': (10000, "10000 ('cwd \"data\" fs.stat pop) times 10000"),
    'filesystem-read': (64 * 65536, "64 ('cwd \"data\" fs.read-bytes len 65536 = assert) times 4194304"),
    'filesystem-staging-cleanup': (1024, "8 ('cwd \"published\" fs.stage-dir 's set 128 range (str s swap fs.mkdirs 0) each pop s port.close) times 1024"),
    'network-connections': (32, "{'address \"127.0.0.1\" 'port 0} net.listen 'l set l net.local-address 'port at str io.print 32 range (pop l net.accept) each 'clients set l net.close clients (dup 1 net.read [65] match? assert net.close 0) each pop 32"),
    'process-duplex': (32, "4096 range 256 mod 'payload set 32 range (pop [] ({'executable \"/bin/cat\"} 'stdin payload dict.put proc.run 'stdout at len) @spawn) each (task.await 'ok at first) each sum 131072 = assert 32"),
}

def run(name, units, source, directory):
    started = time.perf_counter()
    proc = subprocess.Popen([str(binary), '-e', source], cwd=directory,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    peak = {'threads': 0, 'rss_kib': 0}
    stop = threading.Event()
    def sample():
        while not stop.is_set():
            try:
                fields = {}
                for line in pathlib.Path(f'/proc/{proc.pid}/status').read_text().splitlines():
                    key, _, val = line.partition(':')
                    if key in ('Threads', 'VmHWM'):
                        fields[key] = int(val.split()[0])
                peak['threads'] = max(peak['threads'], fields.get('Threads', 0))
                peak['rss_kib'] = max(peak['rss_kib'], fields.get('VmHWM', 0))
            except (FileNotFoundError, ProcessLookupError):
                pass
            stop.wait(.001)
    sampler = threading.Thread(target=sample)
    sampler.start()
    peers = []
    try:
        if name == 'network-connections':
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                if not selector.select(20):
                    raise TimeoutError('listener did not publish its port')
            port = int(proc.stdout.readline())
            for _ in range(32):
                peer = socket.create_connection(('127.0.0.1', port), timeout=20)
                peers.append(peer)
                peer.sendall(b'A')
                peer.shutdown(socket.SHUT_WR)
        stdout, stderr = proc.communicate(timeout=90)
        elapsed = time.perf_counter() - started
        if proc.returncode != 0 or stdout.strip() != str(units).encode():
            raise RuntimeError((name, proc.returncode, stdout.decode(), stderr.decode()))
        if list(pathlib.Path(directory).glob('.ecl-fs-*')) or (pathlib.Path(directory) / 'published').exists():
            raise RuntimeError('filesystem cleanup left unpublished contents')
        return {'seconds': elapsed, 'units_per_second': units / elapsed, **peak}
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, 9)
            proc.wait(timeout=10)
        for peer in peers:
            peer.close()
        stop.set()
        sampler.join(timeout=10)

report = {'commit': a.commit, 'optimization': 'ReleaseSafe', 'target': platform.machine() + '-' + platform.system(),
          'kernel': platform.release(), 'sampling_seconds': .001, 'workloads': {}}
with tempfile.TemporaryDirectory(prefix='ecl-service-perf-', dir=a.output.parent) as directory:
    (pathlib.Path(directory) / 'data').write_bytes(bytes(range(256)) * 256)
    for name, (units, source) in workloads.items():
        if a.workload is not None and name != a.workload:
            continue
        source = source.replace(" assert", " {'kind 'user 'msg \"benchmark result\"} assert")
        run(name, units, source, directory)
        measurements = [run(name, units, source, directory) for _ in range(a.repetitions)]
        report['workloads'][name] = {'units': units, 'source': source, 'measurements': measurements}
        print(name, json.dumps(measurements), flush=True)
a.output.write_text(json.dumps(report, indent=2) + '\n')
