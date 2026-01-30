# Local LLM Server on Debian 13 (Trixie)

**No sudo · No Docker · NVIDIA GPU · Ollama + Open WebUI · uv-managed
Python**

This README describes a **working, Debian-correct** setup for running a
GPU‑accelerated local LLM server with a web interface.

------------------------------------------------------------------------

## Assumptions

-   Fresh Debian 13 (Trixie)
-   Normal user account (example: `pan`)
-   Root access via `su -`
-   NVIDIA RTX GPU
-   Server or headless usage

------------------------------------------------------------------------

## 0) Base system preparation

``` bash
su -
apt update
apt upgrade -y
apt install -y curl ca-certificates gnupg pciutils nano
exit
```

Verify GPU:

``` bash
lspci | grep -i nvidia
```

------------------------------------------------------------------------

## 1) Enable required Debian repositories

``` bash
su -
nano /etc/apt/sources.list
```

Ensure all Debian lines include:

    main contrib non-free non-free-firmware

Example:

    deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
    deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
    deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware

``` bash
apt update
exit
```

------------------------------------------------------------------------

## 2) Install NVIDIA drivers

``` bash
su -
apt install -y   linux-headers-$(uname -r)   build-essential   nvidia-driver   nvidia-cuda-toolkit
reboot
```

Verify after reboot:

``` bash
nvidia-smi
```

------------------------------------------------------------------------

## 3) Install Ollama

``` bash
su -
curl -fsSL https://ollama.com/install.sh | sh
systemctl enable --now ollama
exit
```

Test:

``` bash
ollama run llama3.2
nvidia-smi
```

------------------------------------------------------------------------

## 4) Configure Ollama API

``` bash
su -
systemctl edit ollama.service
```

Add:

    [Service]
    Environment="OLLAMA_HOST=127.0.0.1:11434"
    Environment="OLLAMA_KEEP_ALIVE=24h"

``` bash
systemctl daemon-reload
systemctl restart ollama
curl http://127.0.0.1:11434/api/tags
exit
```

------------------------------------------------------------------------

## 5) Install uv (user-space Python manager)

As normal user:

``` bash
curl -LsSf https://astral.sh/uv/install.sh | sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
uv --version
```

------------------------------------------------------------------------

## 6) Create Open WebUI directories

``` bash
su -
mkdir -p /opt/open-webui /var/lib/open-webui
chown -R pan:pan /opt/open-webui /var/lib/open-webui
exit
```

------------------------------------------------------------------------

## 7) Install Python 3.12 + Open WebUI

``` bash
cd /opt/open-webui
uv python install 3.12
uv venv --python 3.12 --seed /opt/open-webui/venv
source /opt/open-webui/venv/bin/activate
python -m pip install -U pip
python -m pip install open-webui
deactivate
```

------------------------------------------------------------------------

## 8) Test Open WebUI

``` bash
export DATA_DIR=/var/lib/open-webui
export OLLAMA_BASE_URL=http://127.0.0.1:11434
/opt/open-webui/venv/bin/open-webui serve --host 0.0.0.0 --port 8080
```

Open:

    http://<server-ip>:8080

------------------------------------------------------------------------

## 9) Create systemd service

``` bash
su -
nano /etc/systemd/system/open-webui.service
```

Paste:

    [Unit]
    Description=Open WebUI
    After=network.target ollama.service
    Wants=ollama.service

    [Service]
    Type=simple
    Environment=DATA_DIR=/var/lib/open-webui
    Environment=OLLAMA_BASE_URL=http://127.0.0.1:11434
    ExecStart=/opt/open-webui/venv/bin/open-webui serve --host 0.0.0.0 --port 8080
    Restart=always
    RestartSec=3
    NoNewPrivileges=true
    PrivateTmp=true

    [Install]
    WantedBy=multi-user.target

``` bash
systemctl daemon-reload
systemctl enable --now open-webui
exit
```

------------------------------------------------------------------------

## 10) Firewall (optional)

``` bash
su -
apt install -y ufw
ufw allow 8080/tcp
ufw enable
exit
```

------------------------------------------------------------------------

## 11) Pull models

``` bash
ollama pull llama3.2
ollama pull qwen2.5:7b
ollama pull deepseek-coder:6.7b
```

------------------------------------------------------------------------

## Result

-   Debian-native
-   No sudo, no Docker
-   Python 3.12 supported
-   GPU acceleration enabled
-   Web UI available on port 8080
