#!/usr/bin/env bash
# localcode setup for Ubuntu: checks the GPU/CUDA first, then installs
# build packages, llama.cpp (CUDA), OpenCode, and the `localcode` command.
#
#   ./setup.sh            run the setup
#   ./setup.sh --check    only run the GPU/CUDA checks
#   ./setup.sh --dry-run  show what would be done
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
OPENCODE_INSTALL_URL="${OPENCODE_INSTALL_URL:-https://opencode.ai/v2/install}"
CHECK_ONLY=0; DRY=0
for a in "$@"; do
  case $a in
    --check) CHECK_ONLY=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' B=$'\e[1m' N=$'\e[0m'; else R= G= Y= B= N=; fi
ok()   { echo "  ${G}✔${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
step() { echo; echo "${B}$*${N}"; }
die()  { echo; echo "  ${R}✘ $*${N}" >&2; exit 1; }
run()  { if (( DRY )); then echo "  [dry-run] $*"; else "$@"; fi; }

# ---------------------------------------------------------------- preflight
step "1/5  Checking GPU and CUDA"

[[ $(uname -s) == Linux ]] || die "Linux only."
[[ -r /etc/os-release ]] && . /etc/os-release
[[ ${ID:-} == ubuntu ]] || warn "Made for Ubuntu (found: ${PRETTY_NAME:-unknown}); continuing."
(( EUID != 0 )) || warn "Running as root: files will go to root's home."

has_nvidia=0
for v in /sys/bus/pci/devices/*/vendor; do
  [[ -r $v && $(<"$v") == 0x10de ]] || continue
  [[ $(<"${v%vendor}class") == 0x03* ]] && has_nvidia=1
done
(( has_nvidia )) || die "No NVIDIA GPU found. localcode needs an NVIDIA GPU with CUDA. Nothing was installed."
ok "NVIDIA GPU detected"

command -v nvidia-smi >/dev/null 2>&1 \
  || die "NVIDIA driver missing (nvidia-smi not found). Install it first, e.g. 'sudo ubuntu-drivers install', reboot, and re-run. Nothing was installed."
smi=$(timeout 15 nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv,noheader 2>/dev/null | head -1) \
  || true
[[ -n $smi ]] || die "nvidia-smi cannot talk to the driver. Reboot or reinstall the driver, then re-run. Nothing was installed."
IFS=',' read -r gpu_name drv_ver gpu_mem cc <<<"$smi"
gpu_name=${gpu_name# }; drv_ver=${drv_ver# }; gpu_mem=${gpu_mem# }; cc=${cc# }
ok "$gpu_name, $gpu_mem, driver $drv_ver, compute $cc"

drv_cuda=$(timeout 15 nvidia-smi 2>/dev/null | sed -nE 's/.*CUDA (UMD )?Version: *([0-9]+\.[0-9]+).*/\2/p' | head -1)
[[ -n $drv_cuda ]] || die "Could not read the driver's CUDA version from nvidia-smi."

NVCC=$(command -v nvcc || true)
[[ -z $NVCC && -x /usr/local/cuda/bin/nvcc ]] && NVCC=/usr/local/cuda/bin/nvcc
[[ -n $NVCC ]] || die "CUDA toolkit not found (nvcc missing). Install it with 'sudo apt install nvidia-cuda-toolkit' or from developer.nvidia.com/cuda-downloads, then re-run. Nothing was installed."
tk=$("$NVCC" --version | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -1)
[[ -n $tk ]] || die "Could not read the CUDA toolkit version from $NVCC."
ok "CUDA toolkit $tk (driver supports up to $drv_cuda)"

vge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1) == "$2" ]]; }   # $1 >= $2
cc_major=${cc%%.*}
need=11.8; (( cc_major >= 10 )) && need=12.8
vge "$tk" "$need" || die "CUDA toolkit $tk is too old for compute capability $cc (needs >= $need). Upgrade the toolkit and re-run. Nothing was installed."
(( ${tk%%.*} <= ${drv_cuda%%.*} )) || die "CUDA toolkit $tk is newer than the driver supports ($drv_cuda). Update the NVIDIA driver and re-run. Nothing was installed."
ok "Toolkit and driver are compatible"
CUDA_ARCH=${cc/./}

(( CHECK_ONLY )) && { echo; ok "All checks passed."; exit 0; }

# ----------------------------------------------------------------- packages
step "2/5  Installing support packages"
SUDO=; (( EUID == 0 )) || SUDO=sudo
pkgs=(build-essential cmake git curl ca-certificates python3 pkg-config libcurl4-openssl-dev)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if ((${#missing[@]})); then
  echo "  installing: ${missing[*]}"
  run $SUDO apt-get update -qq
  run $SUDO apt-get install -y "${missing[@]}"
else
  ok "all packages already installed"
fi

# ---------------------------------------------------------------- llama.cpp
step "3/5  Building llama.cpp (CUDA, arch $CUDA_ARCH)"
if [[ -x $LLAMA_DIR/build/bin/llama-server ]]; then
  ok "already built: $LLAMA_DIR/build/bin/llama-server"
else
  if [[ -d $LLAMA_DIR/.git ]]; then run git -C "$LLAMA_DIR" pull --ff-only
  else run git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"; fi
  jobs=$(( $(nproc) / 2 )); (( jobs >= 1 )) || jobs=1   # unlimited -j can freeze the machine
  run cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" -DCMAKE_BUILD_TYPE=Release
  run cmake --build "$LLAMA_DIR/build" --config Release -j "$jobs" --target llama-server
  ok "built with $jobs parallel jobs"
fi

# ----------------------------------------------------------------- OpenCode
step "4/5  Installing OpenCode"
if [[ -x $HOME/.opencode/bin/opencode ]] || command -v opencode >/dev/null 2>&1; then
  ok "OpenCode already installed"
elif (( DRY )); then
  echo "  [dry-run] curl -fsSL $OPENCODE_INSTALL_URL | bash"
else
  curl -fsSL "$OPENCODE_INSTALL_URL" | bash \
    || curl -fsSL https://opencode.ai/install | bash \
    || die "OpenCode install failed. See opencode.ai for manual steps."
  ok "OpenCode installed"
fi

# ----------------------------------------------------------------- localcode
step "5/5  Installing the localcode command"
run mkdir -p "$BIN_DIR" "$MODELS_DIR" "$HOME/.config/opencode"
run install -m 755 "$REPO/bin/localcode" "$BIN_DIR/localcode"
ok "$BIN_DIR/localcode"

copy_example() {   # never overwrite the user's files
  if [[ -e $2 ]]; then ok "kept existing $2"
  else run cp "$1" "$2"; ok "created $2"; fi
}
copy_example "$REPO/config/models.ini.example" "$MODELS_DIR/models.ini"
copy_example "$REPO/config/opencode.jsonc.example" "$HOME/.config/opencode/opencode.jsonc"

# put ~/.local/bin and ~/.opencode/bin on PATH for bash and zsh
marker="# >>> localcode >>>"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [[ -f $rc || $rc == "$HOME/.bashrc" ]] || continue
  grep -qF "$marker" "$rc" 2>/dev/null && continue
  if (( DRY )); then echo "  [dry-run] add PATH block to $rc"; continue; fi
  printf '\n%s\nexport PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"\n# <<< localcode <<<\n' "$marker" >> "$rc"
  ok "added PATH block to $rc"
done

echo
echo "${G}${B}Done.${N} Next:"
echo "  1. Download a .gguf model and edit  $MODELS_DIR/models.ini"
echo "  2. Open a new terminal, cd into a project, and run:  localcode"
