#!/bin/sh
# Unit tests for wsl-gpu. They run anywhere (no GPU, no WSL, no root) by
# pointing the tool at a fake /usr/lib/wsl tree.
#   sh tests/run.sh
# SPDX-License-Identifier: MIT
# "cond && pass || fail" is intended: pass and fail always succeed.
# shellcheck disable=SC2015,SC2010,SC2012
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/wsl-gpu"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '     %s\n' "$2"; }

# --- fixture ----------------------------------------------------------------
make_fixture() {
	rm -rf "$T/fx"
	mkdir -p "$T/fx/dev" "$T/fx/lib" "$T/fx/drivers/nvami.inf_amd64_1234abcd" \
		"$T/fx/drivers/u0123456.inf_amd64_amdgpu" "$T/fx/cdi"
	: >"$T/fx/dev/dxg"
	for f in libcuda.so.1 libdxcore.so libd3d12.so libnvidia-ml.so.1 nvidia-smi; do : >"$T/fx/lib/$f"; done
	for f in libcuda.so.1.1 libnvidia-ml.so.1 nvidia-smi; do : >"$T/fx/drivers/nvami.inf_amd64_1234abcd/$f"; done
	: >"$T/fx/drivers/u0123456.inf_amd64_amdgpu/amdxc64.so"
}

run() { # run wsl-gpu against the fixture; output in $OUT, status in $RC
	OUT="$(WSL_GPU_ALLOW_FAKE_DXG=1 \
		WSL_GPU_DXG="$T/fx/dev/dxg" \
		WSL_GPU_LIB_DIR="$T/fx/lib" \
		WSL_GPU_DRIVERS_DIR="$T/fx/drivers" \
		WSL_GPU_CDI_DIR="$T/fx/cdi" \
		sh "$BIN" "$@" 2>&1)"
	RC=$?
}

has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

# --- tests ------------------------------------------------------------------
make_fixture

run version
[ $RC -eq 0 ] && has "wsl-gpu 0." && pass "version" || fail "version" "$OUT"

run help
[ $RC -eq 0 ] && has "generate" && pass "help" || fail "help" "$OUT"

run bogus
[ $RC -eq 2 ] && pass "unknown command exits 2" || fail "unknown command exits 2 (got $RC)"

run generate --stdout
SPEC="$OUT"
[ $RC -eq 0 ] && pass "generate --stdout succeeds" || fail "generate --stdout succeeds" "$OUT"
has 'cdiVersion: "0.6.0"' && pass "spec: cdiVersion" || fail "spec: cdiVersion" "$SPEC"
has 'kind: nvidia.com/gpu' && pass "spec: kind" || fail "spec: kind"
has '- name: all' && pass "spec: device 'all'" || fail "spec: device 'all'"
has '- path: /dev/dxg' && pass "spec: /dev/dxg in container" || fail "spec: /dev/dxg in container"
has "hostPath: \"$T/fx/dev/dxg\"" && pass "spec: hostPath for non-default dxg" || fail "spec: hostPath for non-default dxg"
has "hostPath: \"$T/fx/lib\"" && pass "spec: mounts WSL lib dir" || fail "spec: mounts WSL lib dir"
has 'containerPath: /usr/lib/wsl/lib' && pass "spec: lib dir at /usr/lib/wsl/lib" || fail "spec: lib dir at /usr/lib/wsl/lib"
has 'containerPath: "/usr/lib/wsl/drivers/nvami.inf_amd64_1234abcd"' && pass "spec: mounts NVIDIA driver folder" || fail "spec: mounts NVIDIA driver folder"
has 'amdgpu' && fail "spec: skips non-NVIDIA driver folders" || pass "spec: skips non-NVIDIA driver folders"
has 'LD_LIBRARY_PATH=/usr/lib/wsl/lib:' && pass "spec: LD_LIBRARY_PATH" || fail "spec: LD_LIBRARY_PATH"
has '"ro"' && pass "spec: mounts are read-only" || fail "spec: mounts are read-only"

# Valid YAML with the expected structure (when PyYAML is available).
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
	if printf '%s\n' "$SPEC" | python3 -c '
import sys, yaml
s = yaml.safe_load(sys.stdin)
assert s["kind"] == "nvidia.com/gpu"
assert [d["name"] for d in s["devices"]] == ["all"]
assert s["devices"][0]["containerEdits"]["deviceNodes"][0]["path"] == "/dev/dxg"
m = s["containerEdits"]["mounts"]
assert len(m) == 2, m
assert all("ro" in x["options"] for x in m)
'; then pass "spec: parses as YAML with expected structure"; else fail "spec: parses as YAML with expected structure"; fi
else
	printf 'skip spec: YAML parse (python3 + PyYAML not installed)\n'
fi

run generate
[ $RC -eq 0 ] && [ -s "$T/fx/cdi/nvidia-wsl.yaml" ] && pass "generate writes the spec file" || fail "generate writes the spec file" "$OUT"
ls "$T/fx/cdi" | grep -q '\.tmp\.' && fail "no temp file left behind" || pass "no temp file left behind"
perm="$(ls -l "$T/fx/cdi/nvidia-wsl.yaml" | cut -c1-10)"
[ "$perm" = "-rw-r--r--" ] && pass "spec file is 0644" || fail "spec file is 0644 (got $perm)"

run generate --output "$T/fx/custom/spec.yaml" --quiet
[ $RC -eq 0 ] && [ -s "$T/fx/custom/spec.yaml" ] && [ -z "$OUT" ] && pass "generate --output --quiet" || fail "generate --output --quiet" "$OUT"

# Two driver folders (e.g. leftovers from an update): both are mounted.
mkdir -p "$T/fx/drivers/nv_dispi.inf_amd64_99"
: >"$T/fx/drivers/nv_dispi.inf_amd64_99/libcuda.so.1.1"
run generate --stdout
has 'nv_dispi.inf_amd64_99' && has 'nvami.inf_amd64_1234abcd' && pass "mounts every NVIDIA driver folder" || fail "mounts every NVIDIA driver folder"
make_fixture

# No GPU at all.
rm -f "$T/fx/dev/dxg"
run generate
[ $RC -ne 0 ] && has "not found" && pass "no /dev/dxg: generate fails" || fail "no /dev/dxg: generate fails" "$OUT"
run generate --if-present
[ $RC -eq 0 ] && has "nothing to do" && pass "no /dev/dxg: --if-present exits 0" || fail "no /dev/dxg: --if-present exits 0" "$OUT"
make_fixture

# GPU device present but no NVIDIA driver (AMD/Intel only machine).
rm -rf "$T/fx/drivers/nvami.inf_amd64_1234abcd"
rm -f "$T/fx/cdi/nvidia-wsl.yaml"
run generate
[ $RC -ne 0 ] && has "no NVIDIA driver" && pass "no NVIDIA driver: generate fails" || fail "no NVIDIA driver: generate fails" "$OUT"
run generate --if-present
[ $RC -eq 0 ] && [ ! -e "$T/fx/cdi/nvidia-wsl.yaml" ] && pass "no NVIDIA driver: --if-present writes nothing" || fail "no NVIDIA driver: --if-present writes nothing" "$OUT"
make_fixture

# Missing WSL libraries.
rm -f "$T/fx/lib/libcuda.so.1"
run generate
[ $RC -ne 0 ] && has "libraries not found" && pass "missing libcuda: generate fails" || fail "missing libcuda: generate fails" "$OUT"
make_fixture

# Unsafe path characters are refused instead of producing broken YAML.
mkdir -p "$T/fx/bad\"dir"
OUT="$(WSL_GPU_ALLOW_FAKE_DXG=1 WSL_GPU_DXG="$T/fx/dev/dxg" WSL_GPU_LIB_DIR="$T/fx/bad\"dir" \
	WSL_GPU_DRIVERS_DIR="$T/fx/drivers" sh "$BIN" generate --stdout 2>&1)"
RC=$?
[ $RC -ne 0 ] && pass "refuses quotes in paths" || fail "refuses quotes in paths" "$OUT"

run remove
[ $RC -eq 0 ] && pass "remove with no spec" || fail "remove with no spec" "$OUT"
run generate --quiet
run remove
[ $RC -eq 0 ] && [ ! -e "$T/fx/cdi/nvidia-wsl.yaml" ] && pass "remove deletes the spec" || fail "remove deletes the spec" "$OUT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
