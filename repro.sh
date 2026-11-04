#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
export PATH="$PWD/.bazel_env_tools/bin:$PATH"

mkdir -p .repro
run=$(mktemp -d "$PWD/.repro/run-XXXXXX")
echo "Logs: $run"
echo "Expected in all three cases, through both interfaces: bazel run succeeds and jq --version prints jq-1.8.2."

fail() { echo "ERROR: $*" >&2; exit 1; }

# A fresh, in-memory HTTP AC/CAS cache. No external service or server binary.
python3 - "$run/endpoint" >"$run/cache.log" 2>&1 <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys

blobs = {}

class Cache(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_PUT(self):
        blobs[self.path] = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        body = blobs.get(self.path)
        self.send_response(404 if body is None else 200)
        self.send_header("Content-Length", str(len(body or b"")))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body or b"")

    do_HEAD = do_GET

server = ThreadingHTTPServer(("127.0.0.1", 0), Cache)
Path(sys.argv[1]).write_text(f"http://127.0.0.1:{server.server_port}")
server.serve_forever()
PY
cache_pid=$!
trap 'kill "$cache_pid" 2>/dev/null || true; wait "$cache_pid" 2>/dev/null || true' EXIT
until [[ -s "$run/endpoint" ]]; do
    kill -0 "$cache_pid" 2>/dev/null || { cat "$run/cache.log"; exit 1; }
    sleep 0.1
done

for case in seed hit disabled; do
    flag=--experimental_remote_repo_contents_cache
    [[ $case != disabled ]] || flag=--noexperimental_remote_repo_contents_cache
    echo
    case "$case" in
        seed) echo "[1/3] Seed: cache starts empty; expect both jq paths to work." ;;
        hit) echo "[2/3] Hit: warm cache, fresh output bases; expect both jq paths to work." ;;
        disabled) echo "[3/3] Disabled: warm cache, fresh output bases, flag off; expect both jq paths to work." ;;
    esac
    for interface in toolchains tools; do
        case "$interface" in
            toolchains) target=//:bazel_env; jq=.bazel_env/toolchains/jq/jq ;;
            tools) target=//:bazel_env_tools; jq=.bazel_env_tools/bin/jq ;;
        esac
        echo "Checking $interface via $target..."
        bazel --ignore_all_rc_files --batch \
            --output_user_root="$run/user" --output_base="$run/$case/$interface" "$flag" \
            run "$target" --lockfile_mode=off --repo_contents_cache= \
            --repository_cache="$run/downloads" --disk_cache= \
            --remote_cache="$(cat "$run/endpoint")" --auth_enabled=false \
            --remote_download_outputs=minimal || fail "$case/$interface: bazel run failed"
        echo "Actual: bazel run succeeded."

        echo "+ $jq --version"
        if "$jq" --version >"$run/$case-$interface.stdout" 2>"$run/$case-$interface.stderr"; then
            cat "$run/$case-$interface.stdout"
            [[ $(cat "$run/$case-$interface.stdout") == 'jq-1.8.2' ]] || fail "$case/$interface: unexpected version output"
            if [[ $case == hit && $interface == toolchains ]]; then
                echo "NOT REPRODUCED: cached toolchain executable runs, as it should."
                exit 1
            fi
            echo "PASS: $interface jq --version runs successfully, as expected."
        else
            cat "$run/$case-$interface.stderr"
            [[ $case == hit && $interface == toolchains ]] || fail "$case/$interface: expected jq --version to run after a successful bazel run"
            grep -q 'No such file or directory' "$run/$case-$interface.stderr" || fail "$case/$interface: execution failed for an unexpected reason"
            echo "BUG: bazel run succeeded, but the toolchain jq executable is missing; expected jq --version to run."
        fi
    done
done
echo
echo "REPRODUCED: jq fails only through toolchains on a cache hit; tools works."
