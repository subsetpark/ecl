#!/usr/bin/env python3
"""Hermetic loopback HTTPS fixture for package synchronization tests."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import http.server
import io
import json
import ssl
import tarfile
from typing import Mapping


RAW_BYTES = bytes((0, 1, 127, 128, 255, 195, 40))
ZERO_HASH = "sha256-" + ("0" * 64)


def tgz(files: Mapping[str, bytes]) -> bytes:
    """Build byte-stable USTAR+gzip output independent of host metadata."""
    compressed = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name in sorted(files):
                payload = files[name]
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                info.mode = 0o644
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0
                archive.addfile(info, io.BytesIO(payload))
    return compressed.getvalue()


def digest(payload: bytes) -> str:
    return "sha256-" + hashlib.sha256(payload).hexdigest()


def requirement(version: str, url: str, hash_value: str) -> str:
    return (
        "{'version \""
        + version
        + "\" 'url \""
        + url
        + "\" 'hash \""
        + hash_value
        + "\"}"
    )


def manifest(name: str, version: str, requires: Mapping[str, str]) -> str:
    entries = " ".join(f'\"{key}\" {requires[key]}' for key in sorted(requires))
    return (
        "{'format 1 'name \""
        + name
        + "\" 'version \""
        + version
        + "\" 'requires {"
        + entries
        + "}}\n"
    )


def package(name: str, version: str, requires: Mapping[str, str], modules: Mapping[str, str]) -> bytes:
    files = {"ecl.pkg": manifest(name, version, requires).encode("utf-8")}
    files.update({path: source.encode("utf-8") for path, source in modules.items()})
    return tgz(files)


def build_graph(port: int) -> tuple[dict[str, bytes], dict[str, str]]:
    origin = f"https://127.0.0.1:{port}"
    artifacts: dict[str, bytes] = {}

    c12_path = "/pkg/c-1.2.0.tgz"
    c15_path = "/pkg/c-1.5.0.tgz"
    artifacts[c12_path] = package("c", "1.2.0", {}, {"c.ecl": "((12) 'answer def) 'c @defm\n"})
    artifacts[c15_path] = package("c", "1.5.0", {}, {"c.ecl": "((15) 'answer def) 'c @defm\n"})

    a_path = "/pkg/a-1.0.0.tgz"
    b_path = "/pkg/b-1.0.0.tgz"
    artifacts[a_path] = package(
        "a",
        "1.0.0",
        {"c": requirement("1.2.0", origin + c12_path, digest(artifacts[c12_path]))},
        {"a.ecl": "((1) 'answer def) 'a @defm\n"},
    )
    artifacts[b_path] = package(
        "b",
        "1.0.0",
        {"c": requirement("1.5.0", origin + c15_path, digest(artifacts[c15_path]))},
        {"b.ecl": "((2) 'answer def) 'b @defm\n"},
    )

    bad_path = "/pkg/bad-1.0.0.tgz"
    artifacts[bad_path] = package("bad", "1.0.0", {}, {"bad.ecl": "(() 'noop def) 'bad @defm\n"})

    prefix_path = "/pkg/foo-1.0.0-prefix.tgz"
    artifacts[prefix_path] = package("foo", "1.0.0", {}, {"bar.ecl": "(() 'noop def) 'bar @defm\n"})

    nested_path = "/pkg/foo-1.0.0-nested.tgz"
    artifacts[nested_path] = package("foo", "1.0.0", {}, {"nested/foo.ecl": "(() 'noop def) 'foo @defm\n"})

    native_path = "/pkg/foo-1.0.0-native.tgz"
    artifacts[native_path] = package("foo", "1.0.0", {}, {"foo.eclmod": "fixture native payload\n"})

    missing_manifest_path = "/pkg/foo-1.0.0-missing-manifest.tgz"
    artifacts[missing_manifest_path] = tgz({"foo.ecl": b"(() 'noop def) 'foo @defm\n"})

    invalid_manifest_path = "/pkg/foo-1.0.0-invalid-manifest.tgz"
    artifacts[invalid_manifest_path] = tgz(
        {"ecl.pkg": b"\xff", "foo.ecl": b"(() 'noop def) 'foo @defm\n"}
    )

    identity_path = "/pkg/expected-1.0.0-identity.tgz"
    artifacts[identity_path] = package(
        "actual",
        "1.0.0",
        {},
        {"expected.ecl": "(() 'noop def) 'expected @defm\n"},
    )

    root = manifest(
        "root",
        "0.1.0",
        {
            "a": requirement("1.0.0", origin + a_path, digest(artifacts[a_path])),
            "b": requirement("1.0.0", origin + b_path, digest(artifacts[b_path])),
        },
    )
    variants = {
        "root_manifest": root,
        "hash_mismatch_manifest": manifest(
            "root",
            "0.1.0",
            {"bad": requirement("1.0.0", origin + bad_path, ZERO_HASH)},
        ),
        "prefix_violation_manifest": manifest(
            "root",
            "0.1.0",
            {"foo": requirement("1.0.0", origin + prefix_path, digest(artifacts[prefix_path]))},
        ),
        "identity_mismatch_manifest": manifest(
            "root",
            "0.1.0",
            {
                "expected": requirement(
                    "1.0.0",
                    origin + identity_path,
                    digest(artifacts[identity_path]),
                )
            },
        ),
        "non_success_manifest": manifest(
            "root",
            "0.1.0",
            {"down": requirement("1.0.0", origin + "/status/503", ZERO_HASH)},
        ),
    }
    return artifacts, variants


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    artifacts: dict[str, bytes]
    counts: dict[str, int]


class Handler(http.server.BaseHTTPRequestHandler):
    server: FixtureServer

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/__counts":
            self.respond(json.dumps(self.server.counts, sort_keys=True).encode("utf-8"), "application/json")
            return
        self.server.counts[self.path] = self.server.counts.get(self.path, 0) + 1
        if self.path == "/bytes":
            self.respond(RAW_BYTES, "application/octet-stream")
            return
        if self.path == "/gzip-bytes":
            self.respond(gzip.compress(RAW_BYTES, mtime=0), "application/octet-stream", {"Content-Encoding": "gzip"})
            return
        if self.path == "/redirect-bytes":
            self.send_response(302)
            self.send_header("Location", "/bytes")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/status/503":
            self.respond(b"fixture unavailable\n", "text/plain", status=503)
            return
        payload = self.server.artifacts.get(self.path)
        if payload is None:
            self.respond(b"not found\n", "text/plain", status=404)
            return
        self.respond(payload, "application/gzip")

    def respond(
        self,
        payload: bytes,
        content_type: str,
        headers: Mapping[str, str] | None = None,
        status: int = 200,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    server = FixtureServer(("127.0.0.1", 0), Handler)
    port = int(server.server_address[1])
    server.artifacts, variants = build_graph(port)
    server.counts = {}

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    announcement = {
        "port": port,
        "raw_bytes": list(RAW_BYTES),
        **variants,
    }
    print(json.dumps(announcement, sort_keys=True), flush=True)
    server.serve_forever(poll_interval=0.05)


if __name__ == "__main__":
    main()
