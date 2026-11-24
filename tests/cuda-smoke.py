#!/usr/bin/env python3
"""Real CUDA compute test that needs nothing but the driver (libcuda.so.1).

It JIT-compiles a vector-add kernel from PTX, runs it on the GPU and checks
the result. No CUDA toolkit, PyTorch or big image is needed:

    docker run --rm --device nvidia.com/gpu=all \
        -v "$PWD/tests:/t:ro" python:3.12-slim python3 /t/cuda-smoke.py

SPDX-License-Identifier: MIT
"""
import ctypes
import sys
import time
from ctypes import POINTER, byref, c_char_p, c_float, c_int, c_size_t, c_uint, c_uint64, c_void_p

PTX = b"""
.version 7.0
.target sm_50
.address_size 64
.visible .entry vadd(.param .u64 pa, .param .u64 pb, .param .u64 pc, .param .u32 pn)
{
    .reg .pred p;
    .reg .b32 r<5>;
    .reg .b64 rd<11>;
    .reg .f32 f<4>;
    ld.param.u64 rd1, [pa];
    ld.param.u64 rd2, [pb];
    ld.param.u64 rd3, [pc];
    ld.param.u32 r1, [pn];
    mov.u32 r2, %ctaid.x;
    mov.u32 r3, %ntid.x;
    mov.u32 r4, %tid.x;
    mad.lo.s32 r2, r2, r3, r4;
    setp.ge.u32 p, r2, r1;
    @p bra DONE;
    cvta.to.global.u64 rd4, rd1;
    cvta.to.global.u64 rd5, rd2;
    cvta.to.global.u64 rd6, rd3;
    mul.wide.u32 rd7, r2, 4;
    add.s64 rd8, rd4, rd7;
    add.s64 rd9, rd5, rd7;
    add.s64 rd10, rd6, rd7;
    ld.global.f32 f1, [rd8];
    ld.global.f32 f2, [rd9];
    add.f32 f3, f1, f2;
    st.global.f32 [rd10], f3;
DONE:
    ret;
}
\0"""

try:
    cu = ctypes.CDLL("libcuda.so.1")
except OSError as e:
    sys.exit(f"FAIL: cannot load libcuda.so.1 ({e}). Was the container started with --device nvidia.com/gpu=all?")


def check(rc, what):
    if rc != 0:
        name = c_char_p()
        cu.cuGetErrorName(rc, byref(name))
        sys.exit(f"FAIL: {what} returned {rc} ({(name.value or b'?').decode()})")


cu.cuMemcpyHtoD_v2.argtypes = [c_uint64, c_void_p, c_size_t]
cu.cuMemcpyDtoH_v2.argtypes = [c_void_p, c_uint64, c_size_t]
cu.cuMemFree_v2.argtypes = [c_uint64]
cu.cuLaunchKernel.argtypes = [c_void_p, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint,
                              c_uint, c_void_p, POINTER(c_void_p), c_void_p]

check(cu.cuInit(0), "cuInit")
ver = c_int()
check(cu.cuDriverGetVersion(byref(ver)), "cuDriverGetVersion")
count = c_int()
check(cu.cuDeviceGetCount(byref(count)), "cuDeviceGetCount")
if count.value < 1:
    sys.exit("FAIL: no CUDA device")

dev = c_int()
check(cu.cuDeviceGet(byref(dev), 0), "cuDeviceGet")
name = ctypes.create_string_buffer(256)
check(cu.cuDeviceGetName(name, 256, dev), "cuDeviceGetName")
mem = c_size_t()
check(cu.cuDeviceTotalMem_v2(byref(mem), dev), "cuDeviceTotalMem")
major, minor = c_int(), c_int()
check(cu.cuDeviceGetAttribute(byref(major), 75, dev), "compute capability")
check(cu.cuDeviceGetAttribute(byref(minor), 76, dev), "compute capability")
print(f"device : {name.value.decode()} (sm_{major.value}{minor.value}, {mem.value // 2**20} MiB)")
print(f"driver : CUDA {ver.value // 1000}.{ver.value % 1000 // 10}")

ctx = c_void_p()
check(cu.cuDevicePrimaryCtxRetain(byref(ctx), dev), "cuDevicePrimaryCtxRetain")
check(cu.cuCtxSetCurrent(ctx), "cuCtxSetCurrent")

mod, fn = c_void_p(), c_void_p()
check(cu.cuModuleLoadData(byref(mod), PTX), "cuModuleLoadData (PTX JIT)")
check(cu.cuModuleGetFunction(byref(fn), mod, b"vadd"), "cuModuleGetFunction")

n = 1 << 22  # 4M floats, 16 MiB per buffer
size = n * 4
a = (c_float * n)(*range(n))
b = (c_float * n)(*([2.0] * n))
c = (c_float * n)()

da, db, dc = c_uint64(), c_uint64(), c_uint64()
for d in (da, db, dc):
    check(cu.cuMemAlloc_v2(byref(d), c_size_t(size)), "cuMemAlloc")
check(cu.cuMemcpyHtoD_v2(da.value, a, size), "cuMemcpyHtoD")
check(cu.cuMemcpyHtoD_v2(db.value, b, size), "cuMemcpyHtoD")

args = [c_uint64(da.value), c_uint64(db.value), c_uint64(dc.value), c_uint(n)]
params = (c_void_p * 4)(*[ctypes.cast(byref(x), c_void_p) for x in args])
block = 256
grid = (n + block - 1) // block
t0 = time.perf_counter()
check(cu.cuLaunchKernel(fn, grid, 1, 1, block, 1, 1, 0, None, params, None), "cuLaunchKernel")
check(cu.cuCtxSynchronize(), "cuCtxSynchronize")
ms = (time.perf_counter() - t0) * 1000
check(cu.cuMemcpyDtoH_v2(c, dc.value, size), "cuMemcpyDtoH")

bad = next((i for i in (0, 1, 12345, n // 2, n - 1) if c[i] != a[i] + 2.0), None)
for d in (da, db, dc):
    cu.cuMemFree_v2(d.value)
cu.cuDevicePrimaryCtxRelease(dev)
if bad is not None:
    sys.exit(f"FAIL: wrong result at {bad}: {c[bad]} != {a[bad] + 2.0}")
print(f"kernel : vector add of {n:,} floats OK in {ms:.2f} ms")
print("PASS")
