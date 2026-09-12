#!/usr/bin/env python3
"""Public CLI Git package acceptance against a private HTTPS smart-Git server."""
import argparse
import gzip
import http.server
import io
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tarfile
import tempfile
import threading
from urllib.parse import urlsplit


def run(argv, cwd, env=None, ok=True, timeout=40):
    result = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if (result.returncode == 0) != ok:
        raise AssertionError((argv, result.returncode, result.stdout.decode(errors='replace'), result.stderr.decode(errors='replace')))
    return result.stdout.decode() if ok else result.stderr.decode()


def manifest(name='alpha', version='1.2.0', requires='{}'):
    return ("{'format 2 'name \"" + name + "\" 'version \"" + version
            + "\" 'sources [\"src/*.ecl\"] 'exports [\"" + name + "\"] 'requires " + requires + "}\n")


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('ecl', type=Path)
    args = parser.parse_args()
    ecl = str(args.ecl.resolve())
    certs = Path(__file__).resolve().parent / 'fixtures/pkg'
    with tempfile.TemporaryDirectory(prefix='ecl-git-https-') as temp:
        root = Path(temp)
        repo = root / 'repo.git'
        repo.mkdir()
        run(['git', 'init', '--object-format=sha1', '-b', 'main'], repo)
        run(['git', 'config', 'user.email', 'fixture@example.invalid'], repo)
        run(['git', 'config', 'user.name', 'Fixture'], repo)
        run(['git', 'config', 'uploadpack.allowAnySHA1InWant', 'true'], repo)
        (repo / 'src').mkdir()
        (repo / 'src/alpha.ecl').write_text("[] ((42) 'answer def) 'alpha @defm\n")
        (repo / 'ecl.pkg').write_text(manifest())
        long_path = repo / ('data-' + 'x' * 110)
        long_path.write_bytes(b'ordinary tracked data\x00\xff')
        run(['git', 'add', '.'], repo)
        run(['git', 'commit', '-m', 'package'], repo)
        commit = run(['git', 'rev-parse', 'HEAD'], repo).strip()
        run(['git', 'tag', 'v1.2.0'], repo)
        run(['git', 'tag', '-a', 'annotated', '-m', 'release'], repo)
        server = Server(('127.0.0.1', 0), Handler)
        server.root = root
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certs / 'server.pem', certs / 'server-key.pem')
        server.socket = context.wrap_socket(server.socket, server_side=True)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            origin = f'https://127.0.0.1:{server.server_port}'
            url = origin + '/repo.git'
            project = root / 'project'
            project.mkdir()
            env = {**os.environ, 'ECL_CACHE': str(root / 'cache'), 'ECL_GIT_CA_FILE': str(certs / 'ca.pem')}
            run([ecl, 'pkg', 'init', 'app'], project, env)
            initial = (project / 'ecl.pkg').read_bytes()
            def invoke(*arguments, ok=True, custom_env=env):
                result = run([ecl, 'pkg', *arguments], project, custom_env, ok=ok)
                assert not list((root / 'cache').rglob('.git-fetch-*')), 'staging directory survived'
                return result
            assert 'added alpha 1.2.0' in invoke('add', url, '--tag', 'v1.2.0')
            declared = (project / 'ecl.pkg').read_bytes()
            assert commit.encode() in declared and b"'kind 'git" in declared
            assert not (project / 'ecl.lock').exists(), 'add published a lock'
            assert not list((root / 'cache').rglob('.ecl-package.tgz')), 'add installed a package'
            invoke('add', url, '--tag', 'annotated')
            assert (project / 'ecl.pkg').read_bytes() == declared
            invoke('add', url, '--commit', commit)
            assert (project / 'ecl.pkg').read_bytes() == declared
            invoke('sync')
            lock = (project / 'ecl.lock').read_bytes()
            assert commit.encode() in lock
            assert run([ecl, '-e', 'alpha.answer str io.print'], project, env).strip() == '42'
            seals = list((root / 'cache').rglob('.ecl-package.tgz'))
            assert len(seals) == 1
            artifact = seals[0].read_bytes()
            assert artifact[:10] == bytes([31,139,8,0,0,0,0,0,0,255])
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(artifact))) as tar:
                names = tar.getnames()
                assert names == sorted(names) and long_path.name in names
                assert all(m.uid == 0 and m.gid == 0 and m.mtime == 0 and m.mode == 0o644 for m in tar)
            invoke('verify')
            (repo / 'src/alpha.ecl').write_text("[] ((99) 'answer def) 'alpha @defm\n")
            run(['git', 'add', '.'], repo)
            run(['git', 'commit', '-m', 'move tag'], repo)
            run(['git', 'tag', '-f', 'v1.2.0'], repo)
            shutil.rmtree(root / 'cache')
            invoke('sync')
            assert (project / 'ecl.lock').read_bytes() == lock, 'sync resolved the moved tag'
            assert next((root / 'cache').rglob('.ecl-package.tgz')).read_bytes() == artifact
            for selector, revision in [('--commit', 'f' * 40), ('--commit', commit[:8]), ('--tag', 'main'), ('--branch', 'main')]:
                invoke('add', url, selector, revision, ok=False)
                assert (project / 'ecl.pkg').read_bytes() == declared
                assert (project / 'ecl.lock').read_bytes() == lock
            for bad in [origin + '/auth.git', origin + '/downgrade.git', origin + '/interrupted.git', url.replace('https://', 'https://user:secret@')]:
                invoke('add', bad, '--tag', 'v1.2.0', ok=False)
                assert (project / 'ecl.pkg').read_bytes() == declared
            no_ca = {k: v for k, v in env.items() if k != 'ECL_GIT_CA_FILE'}
            invoke('add', url, '--tag', 'v1.2.0', ok=False, custom_env=no_ca)
            run(['git', 'tag', 'noncommit', 'HEAD^{tree}'], repo)
            invoke('add', url, '--tag', 'noncommit', ok=False)
            (repo / 'link').symlink_to('ecl.pkg')
            run(['git', 'add', '.'], repo)
            run(['git', 'commit', '-m', 'forbidden link'], repo)
            run(['git', 'tag', 'symlink'], repo)
            invoke('add', url, '--tag', 'symlink', ok=False)
            assert (project / 'ecl.pkg').read_bytes() == declared
            # Rejections must preserve both published project records.
            (repo / 'link').unlink()
            for tag, contents in [('legacy', manifest().replace("'format 2", "'format 1")),
                                  ('malformed', '{not a manifest'), ('missing', None)]:
                path = repo / 'ecl.pkg'
                if contents is None:
                    path.unlink()
                else:
                    path.write_text(contents)
                run(['git', 'add', '-A'], repo)
                run(['git', 'commit', '-m', tag], repo)
                run(['git', 'tag', tag], repo)
                invoke('add', url, '--tag', tag, ok=False)
                assert (project / 'ecl.pkg').read_bytes() == declared
                assert (project / 'ecl.lock').read_bytes() == lock
            (repo / 'ecl.pkg').write_text(manifest())
            run(['git', 'add', '.'], repo)
            run(['git', 'update-index', '--add', '--cacheinfo', '160000,' + commit + ',submodule'], repo)
            run(['git', 'commit', '-m', 'submodule'], repo)
            run(['git', 'tag', 'submodule'], repo)
            invoke('add', url, '--tag', 'submodule', ok=False)
            # Repeated blob identities keep this object-count fixture small on wire.
            blob = run(['git', 'rev-parse', 'HEAD:src/alpha.ecl'], repo).strip()
            entries = b''.join(f'100644 blob {blob}\tf{i:06d}\n'.encode() for i in range(100001))
            tree = subprocess.run(['git', 'mktree'], input=entries, cwd=repo,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=True).stdout.decode().strip()
            oversized = run(['git', 'commit-tree', tree, '-m', 'too many files'], repo).strip()
            run(['git', 'tag', 'too-many-files', oversized], repo)
            invoke('add', url, '--tag', 'too-many-files', ok=False)
            assert (project / 'ecl.pkg').read_bytes() == declared
            # A second repository depends transitively on the original pinned tree.
            beta = root / 'beta.git'
            run(['git', 'clone', str(repo), str(beta)], root)
            run(['git', 'config', 'user.email', 'fixture@example.invalid'], beta)
            run(['git', 'config', 'user.name', 'Fixture'], beta)
            run(['git', 'rm', '--cached', 'submodule'], beta)
            run(['git', 'config', 'uploadpack.allowAnySHA1InWant', 'true'], beta)
            (beta / 'src/alpha.ecl').unlink()
            (beta / 'src/beta.ecl').write_text("[] ((alpha.answer 1 +) 'answer def) 'beta @defm\n")
            requires = declared.decode().split("'requires ", 1)[1].strip()[:-1]
            (beta / 'ecl.pkg').write_text(manifest('beta', '2.0.0', requires))
            run(['git', 'add', '-A'], beta)
            run(['git', 'commit', '-m', 'transitive package'], beta)
            run(['git', 'tag', 'beta'], beta)
            invoke('add', origin + '/beta.git', '--tag', 'beta')
            # Leave alpha reachable only through beta, and force both Git fetches.
            root_manifest = (project / 'ecl.pkg').read_text().replace(requires[1:-1], '')
            (project / 'ecl.pkg').write_text(root_manifest)
            shutil.rmtree(root / 'cache')
            invoke('sync')
            assert run([ecl, '-e', 'beta.answer str io.print'], project, env).strip() == '43'
            invoke('verify')
            # Equivalent archive/Git mirrors share the immutable store in a mixed graph.
            git_source = "{'kind 'git 'url \"" + url + "\" 'commit \"" + commit + "\"}"
            archive_source = "{'kind 'archive 'url \"" + origin + "/mirror.tgz\"}"
            mirror_requirement = requires[1:-1].replace(git_source, archive_source)
            assert mirror_requirement != requires[1:-1]
            (project / 'ecl.pkg').write_text(root_manifest.replace("'requires {", "'requires {" + mirror_requirement + ' '))
            invoke('sync', '--offline')
            assert b"'kind 'archive" in (project / 'ecl.lock').read_bytes()
            assert b"'kind 'git" in (project / 'ecl.lock').read_bytes()
            invoke('vendor')
            server.shutdown()
            offline = {**env, 'PATH': '/nonexistent'}
            invoke('sync', '--offline', custom_env=offline)
            invoke('verify', custom_env=offline)
            assert run([ecl, '-e', 'alpha.answer str io.print'], project, offline).strip() == '42'
            assert initial != declared
            print('PASS: Git HTTPS tags, commits, immutable sync, deterministic artifacts, rejection, runtime, vendor and offline')
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)


if __name__ == '__main__':
    main()
