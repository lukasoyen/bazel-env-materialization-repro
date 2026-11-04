# bazel_env toolchain executable missing after a repository-cache hit

With bazel_env.bzl **0.10.0** and startup flag
`--experimental_remote_repo_contents_cache`, `bazel run //:bazel_env` succeeds
but the exposed jq executable can remain virtual. Running it fails with
`No such file or directory`. The same executable exposed through `tools` works.
Verified on Linux with Bazel **9.3.1** and **10.0.0rc2**.

On Linux, with Bazel, Python 3, Bash and standard Unix tools installed, run:

```sh
./repro.sh
```

The script starts an in-memory localhost HTTP cache and streams Bazel's output.
Each of three cases runs both targets with separate fresh output bases (six
Bazel runs total). The cache stops on exit.

`MODULE.bazel` uses [jq.bzl 0.7.0](https://github.com/bazel-contrib/jq.bzl/tree/v0.7.0)
to download **jq 1.8.2**. No custom repository rule or compiler is needed.
`BUILD.bazel` exposes it in two targets:

```starlark
bazel_env(
    name = "bazel_env",
    toolchains = {"jq": "@jq_toolchains//:resolved_toolchain"},
)

bazel_env(
    name = "bazel_env_tools",
    tools = {"jq": "$(JQ_BIN)"},
    toolchains = {"jq": "@jq_toolchains//:resolved_toolchain"},
)
```

**Expected in every case:** Bazel succeeds and the exposed `jq --version`
prints `jq-1.8.2`.

| Case | Cache / flag | Toolchain execution | Tool execution |
| --- | --- | --- | --- |
| Seed | Cache starts empty, flag on | Success | Success |
| Hit | Warm cache, flag on | **ENOENT: expectation violated** | Success |
| Disabled | Warm cache, flag off | Success | Success |

The probes run `.bazel_env/toolchains/jq/jq --version` and
`.bazel_env_tools/bin/jq --version` in every case. Separate output bases prevent
the `tools` probe from materializing the failing toolchain probe's repository.
The tools target uses the resolved toolchain's `JQ_BIN` variable.

The script reports `PASS` for the controls and `BUG` for the failed toolchain
execution. Exit 0 means this pattern was reproduced; exit 1 means an error or
`NOT REPRODUCED` if the cached toolchain executable runs.

Local repository contents caching, disk caching, and inherited Bazel rc files
are disabled. Only the installation directory and archive-download cache are
shared between cases.

In [bazel_env 0.10.0](https://github.com/buildbuddy-io/bazel_env.bzl/blob/v0.10.0/bazel_env.bzl#L414-L454),
toolchains use a string-target symlink without retaining the original files as
staging inputs. The `tools` interface retains executable and runfiles inputs.

Each run retains its outputs and HTTP cache log under `.repro/`; delete that
directory to reclaim space. Both generated `.bazel_env*` symlinks are ignored.
