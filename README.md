# Debian 13 Local LLM Setup Script
## Ollama + Open WebUI (No Docker)

This repository provides a **Bash helper script** to set up a local LLM environment on **Debian 13 (Trixie)** using **Ollama** and **Open WebUI**, with optional NVIDIA GPU support.

This project is intended for **hobbyists, homelabs, and personal servers** who want a reasonably safe and repeatable setup without the complexity of containers.

---

## Scope and intent (important)

This script is **not a production automation framework**.

- It is **not a replacement for Ansible, Salt, Nix, or other configuration-management tools**
- It is designed for **single-node installs**
- It makes reasonable safety checks, but favors clarity and convenience over strict enterprise hardening

If you are managing multiple machines or regulated environments, use a proper CM tool instead.

---

## What the script does

- Installs NVIDIA drivers and CUDA toolkit (Debian packages)
- Installs and configures Ollama as a systemd service
- Deploys Open WebUI as a systemd service (no Docker)
- Manages Python 3.12 using `uv`
- Creates a Python virtual environment with pip
- Optionally pulls a curated set of open-source AI models
- Optionally configures a basic, SSH-safe UFW firewall

---

## Tested on

- Debian 13 (Trixie)
- NVIDIA RTX 3060 (12 GB VRAM)
- Single-node, local install

---

## Known limitations

- Single-node only (no clustering or HA)
- Designed for one GPU
- Not optimized for multi-user concurrency
- No automatic upgrades or rollback
- Not a replacement for configuration management tools (Ansible, Salt, Nix, etc.)

This script is intended for learning, experimentation, and personal servers.

---

## When not to use this

- You manage multiple machines
- You need reproducible fleet-wide deployments
- You require strict security/compliance guarantees

In those cases, use a proper configuration-management system.

---

## Requirements

- Debian 13 (Trixie)
- Root access (`su -`)
- One existing non-root user
- Internet access
- Optional: NVIDIA GPU (12 GB VRAM works well with the default model set)

---

## Usage

```bash
su -
bash setup-ollama-openwebui.sh <username>
```

### Dry-run (recommended first)
```bash
bash setup-ollama-openwebui.sh --dry-run <username>
```

Dry-run prints planned actions without making changes.

---

## Startup reliability note

Services like Ollama and Open WebUI can take a few seconds to become available,
especially on first start or after GPU driver initialization.

To avoid false failures, the script:
- Waits for Ollama’s HTTP API to become reachable after restart
- Uses a best-effort wait for Open WebUI on first start

These waits are **convenience features**, not strict health guarantees.

---

## Environment variables (optional)

### Networking
| Variable | Default |
|--------|--------|
| `OLLAMA_BIND` | `127.0.0.1` |
| `OLLAMA_PORT` | `11434` |
| `WEBUI_BIND` | `0.0.0.0` |
| `WEBUI_PORT` | `8080` |

### Firewall
| Variable | Default |
|--------|--------|
| `UFW_ENABLE` | `0` |
| `UFW_ALLOW_WEBUI` | `1` |
| `SSH_ALLOW` | `1` |
| `SSH_PORT` | auto |

### Model downloads
| Variable | Default |
|--------|--------|
| `PULL_MODELS` | `0` |
| `MODEL_LIST` | curated |

---

## Recommended models (12 GB VRAM friendly)

Default list:
- `llama3.2`
- `qwen2.5:7b`
- `qwen2.5-coder:7b`
- `deepseek-r1:7b`
- `phi3:mini`
- `llava`

Enable pulls:
```bash
PULL_MODELS=1 bash setup-ollama-openwebui.sh <username>
```

---

## Logging

All output is written to:
```
/var/log/ollama-openwebui-setup.log
```

---

## Services installed

- `ollama.service`
- `open-webui.service`

---

## License

MIT License. See the `LICENSE` file.