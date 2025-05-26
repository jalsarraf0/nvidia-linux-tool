# 🚀 NVIDIA Linux Tool

> **Production-ready** installer for NVIDIA drivers & NVENC codec  
> Supports Ubuntu 20.04 and newer (incl. headless & GUI systems)  
> GPUs: GTX 1080 Ti and above  

---

## 📋 Table of Contents

1. [Overview](#-overview)  
2. [Features](#-features)  
3. [Prerequisites](#-prerequisites)  
4. [Installation](#-installation)  
5. [Usage](#-usage)  
6. [Interactive Options](#-interactive-options)  
7. [Troubleshooting & FAQ](#-troubleshooting--faq)  
8. [Uninstallation](#-uninstallation)  
9. [Contributing](#-contributing)  
10. [License](#-license)  

---

## 🔍 Overview

`nvidia-linux-tool` is a single, robust Bash script that:

- Automatically detects your Ubuntu version (20.04+)  
- Chooses the optimal NVIDIA driver source (apt repo or NVIDIA’s official .run)  
- Installs NVIDIA drivers & NVENC/NVDEC libraries  
- Works on **both** desktop (GUI) and headless servers  
- Supports Secure Boot (with MOK enrollment prompts)  
- Offers an **interactive menu** to install NVENC-capable apps (FFmpeg, OBS, HandBrake)  

Designed to “just work” on the FIRST RUN—no manual package juggling required.  

---

## ✨ Features

- ✅ Auto-detect GPU model (GTX 1080 Ti+ and newer)  
- ✅ Enable `universe`/`multiverse`/`restricted` repos  
- ✅ DKMS integration for kernel updates  
- ✅ Blacklist `nouveau` & handle Secure Boot gracefully  
- ✅ Prompt for reboot (never forces it)  
- ✅ Interactive selection of optional NVENC software  
- ✅ Comprehensive logging to `/var/log/nvidia_install_<timestamp>.log`  
- ✅ Idempotent and re-runnable  

---

## 🛠 Prerequisites

1. **Ubuntu version**: 20.04, 22.04, 23.10, 24.04, etc.  
2. **Root** or **sudo** privileges  
3. **Internet** access  
4. **GitHub CLI** (`gh`), if you want to clone or push the repo  

---

## 🏗 Installation

1. **Download the script**  
   ```bash
   wget -O install-nvidia-nvenc.sh      https://raw.githubusercontent.com/jalsarraf0/nvidia-linux-tool/main/install-nvidia-nvenc.sh
   ```
2. **Make it executable**  
   ```bash
   chmod +x install-nvidia-nvenc.sh
   ```
3. **Run as root**  
   ```bash
   sudo ./install-nvidia-nvenc.sh
   ```

   - The script will log to `/var/log/nvidia_install_<timestamp>.log`  
   - Follow on-screen prompts for Secure Boot or optional software  

---

## ▶️ Usage

```bash
# For GUI systems:
sudo ./install-nvidia-nvenc.sh

# For headless servers:
sudo ./install-nvidia-nvenc.sh
```

**What happens on first run?**

1. Enables required Ubuntu repos  
2. Installs DKMS, build tools & headers  
3. Detects recommended driver & installs via `apt`  
4. If `apt` fails, falls back to NVIDIA’s `.run` installer  
5. Disables `nouveau`, rebuilds initramfs  
6. Presents optional NVENC-app menu  
7. Prompts for reboot  

---

## 🔧 Interactive Options

During the **“Optional Software**” step, you can pick:

| Option | Package           | Notes                                       |
|:------:|:------------------|:--------------------------------------------|
| 1️⃣     | FFmpeg            | CLI transcoder with NVENC support           |
| 2️⃣     | OBS Studio        | Streaming/recording software (GUI only)     |
| 3️⃣     | HandBrake         | Video transcoder (CLI & GUI variants)       |
| 4️⃣     | None              | Skip additional installs                    |

_Type numbers separated by spaces (e.g., `1 3`). Press Enter to skip._

---

## ❗ Troubleshooting & FAQ

### Q1: “The installer hung on `[nouveau] module in use`”  
- **Solution:** Reboot once to unload nouveau, re-run the script.

### Q2: “Secure Boot blocked the NVIDIA module”  
1. On reboot, you’ll see a **MOK Manager** prompt.  
2. Choose **Enroll MOK → Continue → Enter password** (set during install).  
3. After reboot, the NVIDIA driver will load.

### Q3: “My GPU isn’t detected!”  
- Ensure you have a compatible GPU (GTX 1080 Ti+).  
- Run `lspci | grep -i nvidia`—if it’s missing, check hardware.

### Q4: “I want to try a newer driver version”  
- Manually edit the `DRIVER_VERSION_FULL` variable at the top of the script.

---

## 🧹 Uninstallation

```bash
# Remove NVIDIA packages installed via apt:
sudo apt-get remove --purge -y 'nvidia-*' libnvidia-*
sudo apt-get autoremove -y

# If you used the .run installer:
sudo /usr/bin/NVIDIA-Uninstall

# Restore nouveau:
sudo rm /etc/modprobe.d/blacklist-nouveau.conf
sudo update-initramfs -u

# Reboot to apply changes:
sudo reboot
```

---

## 🤝 Contributing

Feel free to open issues or pull requests:

1. Fork the repo  
2. Create a feature branch (`git checkout -b feature/awesome-stuff`)  
3. Commit and push (`git commit -m "Add awesome stuff"` + `git push`)  
4. Open a PR on GitHub  

---

## 📜 License

This project is released under the [MIT License](https://opensource.org/licenses/MIT).  

---

> **Happy encoding!** 🎉  
> Questions? Open an issue or reach out on GitHub.


