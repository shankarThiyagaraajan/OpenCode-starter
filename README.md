# localcode

Run [OpenCode](https://opencode.ai) against a local model on your own NVIDIA GPU, using llama.cpp.

`localcode` starts the llama.cpp server, loads your model, frees up VRAM if needed (it can list and close GPU-hungry apps), then launches OpenCode.

## Requirements

- Ubuntu
- NVIDIA GPU with the NVIDIA driver and CUDA toolkit installed

`setup.sh` checks these first. If the GPU, driver or CUDA is missing or too old, it tells you and exits without installing anything.

## Install

```bash
git clone <this-repo> localcode && cd localcode
./setup.sh
```

It installs build packages, builds llama.cpp with CUDA, installs OpenCode, and puts `localcode` in `~/.local/bin`. Existing config files are never overwritten.

Options: `./setup.sh --check` (checks only), `./setup.sh --dry-run`.

## Use

1. Download a `.gguf` model and edit `~/models/models.ini` (one `[section]` per model; the section name is the model ID).
2. Open a new terminal, go to your project, run:

```bash
localcode
```

Other options:

```bash
localcode --lc-model NAME   # use another model from models.ini
localcode --lc-pick         # list GPU consumers and pick some to close
```

Any other arguments are passed to `opencode`.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `LOCALCODE_MODEL` | first / marked in models.ini | model to load |
| `LOCALCODE_INI` | `~/models/models.ini` | presets file |
| `LOCALCODE_MIN_FREE_MIB` | `12000` | free VRAM wanted before loading |
| `NO_COLOR` | unset | disable colours |

Set `# localcode-default: NAME` at the top of `models.ini` to choose the default model.

## Files

| Path | Purpose |
|---|---|
| `~/.local/bin/localcode` | the launcher |
| `~/llama.cpp` | llama.cpp build |
| `~/models/models.ini` | model presets |
| `~/.config/opencode/opencode.jsonc` | OpenCode config |
| `~/llama-server.log` | server log |
