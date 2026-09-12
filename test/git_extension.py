"""Standalone Git port acceptance; repositories deliberately contain no manifest."""
import argparse
import gzip
import io
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading

sys.dont_write_bytecode = True
from pkg_git_https import Handler, Server, run


class SnapshotHandler(Handler):
    def respond(self):
        if self.path.startswith('/stalled'):
            self.server.stalled.set()
            self.server.release.wait(5)
            self.close_connection = True
            return
        super().respond()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('ecl', type=Path)
    parser.add_argument('extension', type=Path)
    args = parser.parse_args()
    binary = str(args.ecl.resolve())
    extension = args.extension.resolve()
    certs = Path(__file__).resolve().parent / 'fixtures/pkg'
    with tempfile.TemporaryDirectory(prefix='ecl-git-extension-') as temporary:
        root = Path(temporary)
        repo = root / 'repo.git'
        repo.mkdir()
        run(['git', 'init', '--object-format=sha1', '-b', 'main'], repo)
        run(['git', 'config', 'user.email', 'fixture@example.invalid'], repo)
        run(['git', 'config', 'user.name', 'Fixture'], repo)
        run(['git', 'config', 'uploadpack.allowAnySHA1InWant', 'true'], repo)
        (repo / 'plain.txt').write_bytes(b'ordinary repository\x00\xff')
        long_name = 'long-' + 'x' * 110
        (repo / long_name).write_bytes(b'long path')
        run(['git', 'add', '.'], repo)
        run(['git', 'commit', '-m', 'snapshot'], repo)
        commit = run(['git', 'rev-parse', 'HEAD'], repo).strip()
        run(['git', 'tag', 'release'], repo)
        run(['git', 'tag', '-a', 'annotated', '-m', 'release'], repo)
        server = Server(('127.0.0.1', 0), SnapshotHandler)
        server.root = root
        server.stalled = threading.Event()
        server.release = threading.Event()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certs / 'server.pem', certs / 'server-key.pem')
        server.socket = context.wrap_socket(server.socket, server_side=True)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            caller = root / 'caller'
            caller.mkdir()
            scratch = root / 'scratch'
            scratch.mkdir()
            module_map = caller / 'map'
            module_map.write_text(
                "{'format 1 'local \"root\" 'scopes {\"root\" {'root "
                + json.dumps(str(extension.parent))
                + " 'visible [] 'sources [] 'artifacts [{'path "
                + json.dumps(extension.name) + " 'kind 'native 'exports [\"git\"]}]}}}"
            )
            origin = f'https://127.0.0.1:{server.server_port}'

            def request(selector='commit', revision=commit, **overrides):
                values = {'url': origin + '/repo.git', 'selector': "'" + selector,
                          'revision': revision, 'ca-file': str(certs / 'ca.pem'),
                          'scratch': str(scratch), 'timeout-ms': 3000}
                values.update(overrides)
                return '{' + ' '.join("'" + key + ' ' + (value if key == 'selector' else json.dumps(value))
                                      for key, value in values.items()) + '}'

            def invoke(source, ok=True):
                result = subprocess.run(
                    [binary, '--module-map', str(module_map), '-e', source], cwd=caller,
                    env={**os.environ, 'ECL_WORKERS': '4'}, stdin=subprocess.DEVNULL,
                    capture_output=True, text=True, timeout=20,
                )
                assert result.returncode in ((0,) if ok else (1, 2)), (result.returncode, result.stderr)
                assert 'ThreadSanitizer' not in result.stderr, result.stderr
                assert list(scratch.iterdir()) == [], 'scratch survived joined completion'
                return result.stdout if ok else result.stderr

            def fetch(req, filename):
                return (
                    'git.snapshot [] port.open \'p set p git.fetch ' + req + ' port.begin \'x set '
                    'x git.output port.endpoint \'r set [] r 65536 port.read '
                    '(dup empty? not) (cat r 65536 port.read) while pop '
                    "'cwd " + json.dumps(filename) + ' fs.create-bytes '
                    'x port.result x port.close p port.close'
                )

            for selector, revision, filename in [('tag', 'release', 'tag.tgz'),
                                                  ('tag', 'annotated', 'annotated.tgz'),
                                                  ('commit', commit, 'commit.tgz')]:
                assert invoke(fetch(request(selector, revision), filename)).strip() == json.dumps(commit)
            artifact = (caller / 'commit.tgz').read_bytes()
            assert artifact == (caller / 'tag.tgz').read_bytes() == (caller / 'annotated.tgz').read_bytes()
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(artifact))) as archive:
                assert archive.getnames() == sorted([long_name, 'plain.txt'])
                assert all(member.isfile() and member.uid == 0 and member.gid == 0
                           and member.mode == 0o644 and member.mtime == 0 for member in archive)
                assert archive.extractfile('plain.txt').read() == b'ordinary repository\x00\xff'

            # A moved tag changes only tag resolution; full commits stay reproducible.
            (repo / 'plain.txt').write_text('moved')
            run(['git', 'add', '.'], repo)
            run(['git', 'commit', '-m', 'move'], repo)
            run(['git', 'tag', '-f', 'release'], repo)
            assert invoke(fetch(request(), 'again.tgz')).strip() == json.dumps(commit)
            assert (caller / 'again.tgz').read_bytes() == artifact
            moved = invoke(fetch(request('tag', 'release'), 'moved.tgz')).strip()
            assert moved != json.dumps(commit)

            for overrides in [{'url': 1}, {'revision': []}, {'selector': 'branch'},
                              {'memory-bytes': -1}, {'unknown': 0}]:
                diagnostic = invoke(fetch(request(**overrides), 'bad-request.tgz'), ok=False)
                assert "'kind 'domain" in diagnostic, diagnostic

            for overrides in [{'revision': 'f' * 40}, {'revision': commit[:8]},
                              {'ca-file': ''}, {'url': origin + '/auth.git'},
                              {'url': origin + '/downgrade.git'},
                              {'url': origin + '/interrupted.git'},
                              {'url': origin.replace('https://', 'https://user:secret@') + '/repo.git'},
                              {'files': 1}, {'export-bytes': 1}, {'transfer-bytes': 1},
                              {'objects': 1}, {'memory-bytes': 1}, {'memory-bytes': 4096},
                              {'url': origin + '/stalled.git', 'timeout-ms': 100}]:
                invoke(fetch(request(**overrides), 'failed.tgz'), ok=False)
                assert not (caller / 'failed.tgz').exists()

            # Cancellation of an unread large export interrupts byte backpressure.
            (repo / 'large').write_bytes(b'x' * (512 * 1024))
            run(['git', 'add', '.'], repo)
            run(['git', 'commit', '-m', 'large'], repo)
            run(['git', 'tag', 'large'], repo)
            begin = 'git.snapshot [] port.open \'p set p git.fetch ' + request('tag', 'large') + ' port.begin \'x set '
            invoke(begin + 'x git.output port.endpoint 1 port.read pop x port.cancel x port.close p port.close')
            invoke(begin + 'x git.output port.endpoint 1 port.read pop '
                   'git.snapshot [] port.open \'q set q git.fetch ' + request() +
                   ' port.begin \'y set y port.cancel y port.close q port.close '
                   'x port.cancel x port.close p port.close')
            # Reuse a resource after successful operations and join all closes.
            for number in range(3):
                assert invoke(fetch(request(), f'repeat-{number}.tgz')).strip() == json.dumps(commit)
            repeated = ' '.join(fetch(request(), f'same-session-{number}.tgz') for number in range(3))
            assert invoke(repeated).strip() == ' '.join([json.dumps(commit)] * 3)
            concurrent = (
                '[] (' + fetch(request(), 'concurrent-a.tgz') + ') @spawn \'a set '
                '[] (' + fetch(request(), 'concurrent-b.tgz') + ') @spawn \'b set '
                "a task.await 'ok at first b task.await 'ok at first"
            )
            assert invoke(concurrent).strip() == ' '.join([json.dumps(commit)] * 2)
            recovered = (
                '[] (' + fetch(request(**{'ca-file': ''}), 'untrusted.tgz') +
                ") @attempt 'err at 'kind at " + fetch(request(), 'trusted.tgz')
            )
            assert invoke(recovered).strip() == "'io " + json.dumps(commit)
            # Cancellation while a network read is stalled remains joined.
            begin = 'git.snapshot [] port.open \'p set p git.fetch ' + request(url=origin + '/stalled.git', **{'timeout-ms': 200}) + ' port.begin \'x set '
            invoke(begin + '50 clock.sleep x port.cancel x port.close p port.close')

            # A link is rejected even though the repository has no package metadata.
            (repo / 'link').symlink_to('plain.txt')
            run(['git', 'add', '.'], repo)
            run(['git', 'commit', '-m', 'link'], repo)
            run(['git', 'tag', 'link'], repo)
            invoke(fetch(request('tag', 'link'), 'link.tgz'), ok=False)
        finally:
            server.release.set()
            server.shutdown()
            worker.join(timeout=5)
            server.server_close()
    print('standalone Git snapshot extension: passed')


if __name__ == '__main__':
    main()
