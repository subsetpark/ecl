#!/usr/bin/env python3
"""Controlled HTTPS smart-Git transport fixture; package assertions live in ECL."""
import http.server
import os
import ssl
import subprocess
from urllib.parse import urlsplit


def run(argv, cwd, env=None, ok=True, timeout=40):
    result = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if (result.returncode == 0) != ok:
        raise AssertionError((argv, result.returncode, result.stdout.decode(errors='replace'), result.stderr.decode(errors='replace')))
    return result.stdout.decode() if ok else result.stderr.decode()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        url = urlsplit(self.path)
        if url.path.startswith('/auth'):
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
            self.end_headers()
            return
        if url.path.startswith('/downgrade'):
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:1/repo.git/info/refs?service=git-upload-pack')
            self.end_headers()
            return
        if url.path.startswith('/interrupted'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-git-upload-pack-advertisement')
            self.send_header('Content-Length', '999999')
            self.end_headers()
            self.wfile.write(b'001e# service=git-upload-pack\n')
            self.close_connection = True
            return
        env = {**os.environ, 'GIT_PROJECT_ROOT': str(self.server.root), 'GIT_HTTP_EXPORT_ALL': '1',
               'PATH_INFO': url.path, 'QUERY_STRING': url.query, 'REQUEST_METHOD': self.command,
               'CONTENT_TYPE': self.headers.get('Content-Type', ''),
               'CONTENT_LENGTH': self.headers.get('Content-Length', '0')}
        body = self.rfile.read(int(env['CONTENT_LENGTH']))
        out = subprocess.run(['git', 'http-backend'], input=body, env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        headers, content = out.stdout.split(b'\r\n\r\n', 1)
        fields = [line.decode().split(':', 1) for line in headers.split(b'\r\n')]
        status = next((int(v.strip().split()[0]) for k, v in fields if k.lower() == 'status'), 200)
        self.send_response(status)
        for k, v in fields:
            if k.lower() != 'status':
                self.send_header(k, v.strip())
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        try:
            self.wfile.write(content)
        except (BrokenPipeError, ssl.SSLError):
            pass
