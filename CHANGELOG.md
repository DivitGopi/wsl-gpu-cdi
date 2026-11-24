# Changelog

## 0.1.0 - 2026-11-24

First release.

- `wsl-gpu generate`: writes a CDI spec (`nvidia.com/gpu=all`) that gives
  containers `/dev/dxg`, `/usr/lib/wsl/lib` and the NVIDIA driver-store folder,
  found automatically. Atomic write, `--if-present` for boot scripts.
- `wsl-gpu doctor [--run-test]`: checks WSL2, the GPU device, the libraries,
  the driver folder, the spec and Docker's CDI support, then runs `nvidia-smi`
  in a container.
- `wsl-gpu smi`: `nvidia-smi` on the host (with `gcompat`) or in a container.
- OpenRC service and systemd unit that rebuild the spec at boot, before Docker.
- `install.sh` with `--with-gcompat` and `--uninstall`.
- Tests: 28 unit tests (BusyBox ash, dash, bash), a Docker CDI end-to-end check
  in CI, and `tests/cuda-smoke.py`, a real CUDA kernel launch that needs only the
  driver.
