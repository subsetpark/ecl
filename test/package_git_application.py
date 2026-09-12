"""Own Git servers and fresh checkouts; package assertions run in ECL tests."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
from git_https_fixture import Handler, Server, run


def main():
    supplied_binary = Path(sys.argv[1]).resolve()
    extension = Path(sys.argv[2]).resolve()
    sources = Path('apps/pkg').resolve()
    certs = Path('test/fixtures/pkg').resolve()
    fixture_directory = sources / 'test/fixtures'
    archive_hash = 'sha256-' + hashlib.sha256(bytes.fromhex((fixture_directory / 'valid.tgz.hex').read_text())).hexdigest()
    with tempfile.TemporaryDirectory(prefix='ecl-package-git-') as temporary:
        root = Path(temporary)
        binary = root / 'distribution/bin/ecl'
        binary.parent.mkdir(parents=True)
        shutil.copy2(supplied_binary, binary)
        installed = root / 'distribution/share/ecl/apps/pkg'
        shutil.copytree(sources / 'src', installed / 'src')
        for source, target in [('main.ecl', 'main.ecl'), ('application.json', 'application.json'), ('installed.modules', 'ecl.modules')]:
            shutil.copy2(sources / source, installed / target)
        shutil.copy2(extension, installed / 'git.eclmod')
        app_map = root / 'acceptance.modules'
        app_map.write_text(
            "{'format 1 'local \"tests\" 'scopes {\"tests\" {'root " + json.dumps(str(sources))
            + " 'visible [] 'sources [\"src/**/*.ecl\" \"test/acceptance/git-commands.ecl\"] 'artifacts []}}}"
        )
        repo = root / 'repo.git'
        repo.mkdir()
        run(['git', 'init', '--object-format=sha1', '-b', 'main'], repo)
        run(['git', 'config', 'user.email', 'fixture@example.invalid'], repo)
        run(['git', 'config', 'user.name', 'Fixture'], repo)
        run(['git', 'config', 'uploadpack.allowAnySHA1InWant', 'true'], repo)
        (repo / 'src').mkdir()

        def commit(version, answer):
            (repo / 'ecl.pkg').write_text(
                "{'format 2 'name \"alpha\" 'version " + json.dumps(version)
                + " 'sources [\"src/*.ecl\"] 'exports [\"alpha\"] 'requires {\"sample\" "
                + "{'package \"sample\" 'version \"1.0.0\" 'source {'kind 'archive 'url \"https://fixture.invalid/sample.tgz\"} 'hash "
                + json.dumps(archive_hash) + "}}}"
            )
            (repo / 'src/alpha.ecl').write_text("[] ((" + str(answer) + ") 'answer def) 'alpha @defm\n")
            run(['git', 'add', '.'], repo)
            run(['git', 'commit', '-m', version], repo)
            return run(['git', 'rev-parse', 'HEAD'], repo).strip()

        old_commit = commit('1.0.0', 42)
        run(['git', 'tag', 'release'], repo)
        server = Server(('127.0.0.1', 0), Handler)
        server.root = root
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certs / 'server.pem', certs / 'server-key.pem')
        server.socket = context.wrap_socket(server.socket, server_side=True)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        cache = root / 'cache'
        scratch = root / 'scratch'
        scratch.mkdir()
        env = {**os.environ, 'ECL_CACHE': str(cache), 'ECL_GIT_CA_FILE': str(certs / 'ca.pem'),
               'TMPDIR': str(scratch), 'ECL_WORKERS': '4'}
        url = f'https://127.0.0.1:{server.server_port}/repo.git'

        def phase(name, project, new_commit=''):
            result = subprocess.run(
                [str(binary), '--module-map', str(app_map), 'test', '--runner', 'pkg.test.git-commands.run',
                 '--', name, url, old_commit, new_commit, str(fixture_directory)],
                cwd=project, env=env, stdin=subprocess.DEVNULL, timeout=600,
            )
            if result.returncode:
                raise SystemExit(result.returncode)
            print('package Git application phase:', name, flush=True)

        def checkout(name, source):
            project = root / name
            project.mkdir()
            for filename in ['ecl.pkg', 'ecl.lock']:
                shutil.copy2(source / filename, project / filename)
            return project

        try:
            project = root / 'project'
            project.mkdir()
            phase('initial', project)
            new_commit = commit('2.0.0', 99)
            run(['git', 'tag', '-f', 'release'], repo)
            fresh_old = checkout('fresh-old', project)
            shutil.rmtree(cache)
            phase('reproduce-old', fresh_old, new_commit)
            phase('moved', project, new_commit)
            fresh_new = checkout('fresh-new', project)
            phase('reproduce-new', fresh_new, new_commit)
            shutil.rmtree(cache)
            relocated = root / 'relocated'
            fresh_new.rename(relocated)
            phase('vendor', relocated, new_commit)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)


if __name__ == '__main__':
    main()
