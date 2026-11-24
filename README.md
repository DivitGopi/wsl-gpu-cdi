# wsl-gpu-cdi

**Use your NVIDIA GPU in Docker containers on Alpine Linux under WSL2: no
nvidia-container-toolkit, no glibc, no systemd.**

On Ubuntu under WSL2 you install NVIDIA's container toolkit and run
`docker run --gpus all`. On Alpine there is no such package: the toolkit is
built for glibc distributions and refreshes its config through systemd, while
Alpine uses musl and OpenRC.

`wsl-gpu` closes that gap with one small POSIX shell script. It writes a
[CDI](https://github.com/cncf-tags/container-device-interface) spec that tells
Docker what a container needs to reach the GPU WSL2 already provides. Docker
reads CDI specs natively, so nothing else is required.

```console
$ docker run --rm --device nvidia.com/gpu=all ubuntu:24.04 /usr/lib/wsl/lib/nvidia-smi -L
GPU 0: NVIDIA GeForce GTX 1650 (UUID: GPU-0cbff902-...)
```

## Install

Inside your Alpine WSL2 distro:

```sh
doas apk add git
git clone https://github.com/DivitGopi/wsl-gpu-cdi
cd wsl-gpu-cdi
doas ./install.sh            # add --with-gcompat to also run nvidia-smi on the host
wsl-gpu doctor --run-test
```

`install.sh` puts `wsl-gpu` in `/usr/local/bin` and adds a boot service (OpenRC,
or systemd on other distros) that rebuilds the spec before Docker starts.
Remove everything with `doas ./install.sh --uninstall`.

### Requirements

| | |
|---|---|
| Windows | A current NVIDIA Windows driver (WSL support ships in the regular Game Ready / Studio drivers). Do **not** install a Linux NVIDIA driver inside WSL. |
| WSL | WSL2 (`wsl --version`); `/dev/dxg` must exist in the distro |
| Docker | 25 or newer with CDI enabled (on by default in recent releases; `wsl-gpu doctor` checks) |
| Distro | Any with a POSIX shell. Built for and tested on Alpine. |

## Usage

```sh
# Any glibc image works: PyTorch, TensorFlow, nvidia/cuda, python:slim + pip.
# Pin a version tag: pytorch/pytorch:latest is rarely updated.
docker run --rm --device nvidia.com/gpu=all pytorch/pytorch:<version-tag> \
  python -c "import torch; print(torch.cuda.get_device_name(0))"
```

Docker Compose:

```yaml
services:
  trainer:
    image: pytorch/pytorch:latest
    devices:
      - nvidia.com/gpu=all
```

Commands:

| Command | What it does |
|---|---|
| `wsl-gpu generate` | Detect the GPU and write `/var/run/cdi/nvidia-wsl.yaml` (`--stdout`, `--output FILE`, `--if-present`, `--quiet`) |
| `wsl-gpu doctor [--run-test]` | Check every piece of the setup and say what to fix |
| `wsl-gpu smi [args]` | `nvidia-smi` on the host (with `gcompat`) or in a container |
| `wsl-gpu remove` | Delete the generated spec |

## How it works

```
Windows NVIDIA driver
   │  WSL2 provides in every distro:
   │    /dev/dxg                              GPU paravirtualisation device
   │    /usr/lib/wsl/lib                      libcuda, libnvidia-ml, nvidia-smi
   │    /usr/lib/wsl/drivers/nv*.inf_amd64_*  NVIDIA user-mode driver
   ▼
wsl-gpu generate  ──►  /var/run/cdi/nvidia-wsl.yaml
   ▼
docker run --device nvidia.com/gpu=all ...
   container gets /dev/dxg + both folders (read-only) + LD_LIBRARY_PATH
```

The spec holds three things, found by testing what CUDA actually needs:

1. **`/dev/dxg`**, the device that carries GPU calls to the Windows driver.
2. **`/usr/lib/wsl/lib`**, the stub libraries (`libcuda.so.1`, `libdxcore.so`, ...).
3. **The NVIDIA folder of the Windows driver store** (for example
   `nvami.inf_amd64_1a0e2bbd...`). Without it NVML reports "Driver Not Loaded".
   Its name changes with every Windows driver update, which is why the spec is
   rebuilt at boot instead of being written once. Only this folder is mounted,
   not the whole driver store (4.7 GB on the test machine).

The host never loads a glibc binary. That's why this works on musl.

## Tested on

| | |
|---|---|
| GPU | NVIDIA GeForce GTX 1650 (4 GB, sm_75), laptop with AMD Radeon iGPU |
| Windows driver | 610.74 (CUDA 13.3) |
| WSL | 2.7.10, kernel 6.18.33.2 |
| Distro | Alpine 3.24.4, Docker 29.9.3, Compose 5.7.2 |
| Results | `nvidia-smi` ✅ · CUDA kernel via `tests/cuda-smoke.py` ✅ · Compose ✅ · PyTorch 2.2.1 / CUDA 12.1: `cuda.is_available()`, 4096² matmul at ~1.65 TFLOPS fp32, training loop ✅ · spec rebuilt on cold boot ✅ |

Tested on other hardware? Please open an issue or PR with your `wsl-gpu doctor` output.

## Limitations

- **Use `--device nvidia.com/gpu=all`, not `--gpus all`.** Docker 29 maps `--gpus`
  to a vendor CDI spec it picks itself, and on machines with an AMD iGPU it can
  pick AMD ("AMD CDI spec not found").
- **One device, `all`.** WSL2 exposes every GPU through one `/dev/dxg`, so a
  single GPU can't be selected the way `nvidia.com/gpu=0` works on native Linux.
- **`LD_LIBRARY_PATH` is set by the spec** to
  `/usr/lib/wsl/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64`, the same
  paths NVIDIA's images expect. An image that relies on its own
  `LD_LIBRARY_PATH` should add `/usr/lib/wsl/lib` to it, or set
  `WSL_GPU_LD_LIBRARY_PATH` before `wsl-gpu generate`.
- **CUDA inside the Alpine host itself is not supported.** CUDA, PyTorch and
  friends are glibc builds. Run them in containers; that is what this tool is for.
- **NVIDIA only** for now. AMD and Intel GPUs also appear through `/dev/dxg`
  (DirectX 12 / D3D12 Mesa) and could get their own CDI kinds later.

## Troubleshooting

Run `wsl-gpu doctor`. Common fixes:

| Message | Fix |
|---|---|
| `/dev/dxg missing` | Update the Windows NVIDIA driver and run `wsl --update`, then `wsl --shutdown` |
| `no NVIDIA driver folder` | The Windows driver is too old or not an NVIDIA GPU |
| `CDI is off` | Add `{"features":{"cdi":true}}` to `/etc/docker/daemon.json`, restart Docker |
| `unresolvable CDI devices nvidia.com/gpu=all` | The spec is missing: `doas wsl-gpu generate` |
| `spec does not mount ...` after a driver update | `doas wsl-gpu generate` (or restart WSL) |

## Development

```sh
sh tests/run.sh                  # unit tests, no GPU needed
shellcheck -s sh bin/wsl-gpu install.sh tests/run.sh init/openrc/wsl-gpu-cdi
docker run --rm --device nvidia.com/gpu=all -v "$PWD/tests:/t:ro" \
  python:3.12-slim python3 /t/cuda-smoke.py    # real GPU test
```

CI runs ShellCheck, the unit tests under BusyBox ash, dash and bash, and an
end-to-end check that Docker accepts the spec and applies it.

## License

MIT. Not affiliated with NVIDIA or Microsoft.
