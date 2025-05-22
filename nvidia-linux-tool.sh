#!/bin/bash
# NVIDIA Driver and NVENC Installation Script for Ubuntu 20.04+ 
# 
# This script ensures NVIDIA GPU drivers and NVENC codec support are installed reliably.
# It automatically selects the best installation source (Ubuntu apt packages or NVIDIA's official installer)
# based on system compatibility and stability. It supports both GUI desktops and headless servers, 
# for NVIDIA GPUs from GTX 1080 Ti and newer.
#
# The script also offers an interactive menu to install optional software that can utilize NVENC 
# (e.g., FFmpeg, OBS Studio, HandBrake). It includes extensive error checking, logging, and will prompt for a reboot if needed.
#
# **Usage:** Run this script with root privileges (e.g., via sudo) on an Ubuntu 20.04 or newer system.

####### Initialization and Logging ########

# Require root privileges to run (many installation steps need sudo).
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root. Please re-run with sudo or as root." >&2
    exit 1
fi

# Set up a log file to record all actions for traceability.
LOGFILE="/var/log/nvidia_install_$(date +%F_%T).log"
# Create the log file and open file descriptors for logging.
touch "$LOGFILE" || { echo "Error: Cannot write to $LOGFILE. Check permissions." >&2; exit 1; }
# Tee all script output to the log file (both stdout and stderr).
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== NVIDIA NVENC Installer Script started on $(date) ==="
echo "Logging to $LOGFILE"

# Make bash exit on errors and unset variables, and propagate pipefailures.
set -uo pipefail

# Trap any error (non-zero exit code) in the script to handle it gracefully.
trap 'echo "Error: An unexpected issue occurred. Please check the log at $LOGFILE for details." >&2' ERR

# Basic system info for the log:
OS_NAME=$(lsb_release -ds 2>/dev/null || echo "$ID $VERSION_ID")
KERNEL_VER=$(uname -r)
echo "System: $OS_NAME, Kernel: $KERNEL_VER"

####### System Compatibility Checks ########

# Confirm this is an Ubuntu system of version 20.04 or newer.
. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    echo "Warning: This script is intended for Ubuntu systems. Continuing with caution..." 
fi
UBUNTU_VERSION=${VERSION_ID:-0}
# Strip quotes in VERSION_ID (in case it's quoted, e.g. "20.04").
UBUNTU_VERSION=${UBUNTU_VERSION//\"/}
# Check minimum supported version (20.04).
# Using 20.04 as "20.04", need to handle numeric comparison carefully (convert to integer for major.minor).
# We'll compare major and minor separately to allow comparing versions like 20.04 vs 19.10.
UBUNTU_MAJOR=${UBUNTU_VERSION%%.*}
UBUNTU_MINOR=${UBUNTU_VERSION#*.}
if (( UBUNTU_MAJOR < 20 )) || ( ((UBUNTU_MAJOR == 20)) && (( ${UBUNTU_MINOR%%.*} < 4 )) ); then
    echo "Error: Ubuntu 20.04 or newer is required. Detected version $UBUNTU_VERSION is not supported."
    exit 1
fi

# Detect if an NVIDIA GPU is present.
# We'll search the PCI devices list for NVIDIA. 
if ! lspci -nnk | grep -q -E "VGA|3D|Display.*NVIDIA"; then
    echo "Error: No NVIDIA GPU detected on this system. Aborting installation." >&2
    exit 1
fi

# Retrieve the GPU model name (for logging/informational purposes).
GPU_MODEL=$(lspci -nnk | grep -E "VGA|3D|Display" | grep "NVIDIA" | sed -E 's/.*NVIDIA Corporation *//')
echo "Detected NVIDIA GPU: ${GPU_MODEL:-unknown model}"

# Check if Secure Boot is enabled, because it affects driver loading.
SECURE_BOOT="unknown"
if command -v mokutil >/dev/null 2>&1; then
    # Use mokutil to check Secure Boot state.
    if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot\s*enabled"; then
        SECURE_BOOT="enabled"
    else
        SECURE_BOOT="disabled"
    fi
else
    # If mokutil is not available, attempt to read SecureBoot UEFI variable.
    if [[ -e /sys/firmware/efi/efivars/SecureBoot-* ]]; then
        sb_status=$(hexdump -v -e '1/1 "%x"' /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -c1)
        if [[ "$sb_status" == "1" ]]; then
            SECURE_BOOT="enabled"
        elif [[ "$sb_status" == "0" ]]; then
            SECURE_BOOT="disabled"
        fi
    fi
fi
echo "Secure Boot: $SECURE_BOOT"
if [[ "$SECURE_BOOT" == "enabled" ]]; then
    echo "Note: Secure Boot is enabled. The script will attempt to install signed drivers or use DKMS to build modules."
    echo "      You may be prompted to enroll a Machine Owner Key (MOK) on reboot, or need to disable Secure Boot for the NVIDIA driver to load."
fi

####### APT Repository Configuration ########

echo "Enabling necessary Ubuntu repositories (universe, multiverse, restricted) to ensure all packages are available..."
# The NVIDIA proprietary drivers are typically in the 'restricted' component.
# FFmpeg is in 'universe', and some codec/graphics libraries may be in 'multiverse'.
# Ensure these repositories are enabled:
apt-get update -y || { echo "Error: apt update failed. Check your network connection or apt configuration." >&2; exit 1; }
apt-get install -y software-properties-common || { echo "Error: Failed to install software-properties-common (required for add-apt-repository)." >&2; exit 1; }
add-apt-repository -y universe || echo "Warning: Unable to enable 'universe' repository (it might already be enabled)."
add-apt-repository -y multiverse || echo "Warning: Unable to enable 'multiverse' repository (it might already be enabled)."
add-apt-repository -y restricted || echo "Warning: Unable to enable 'restricted' repository (it might already be enabled)."
apt-get update -y || { echo "Error: apt update failed after enabling repositories." >&2; exit 1; }

# Install prerequisite packages for building drivers and detecting hardware.
echo "Installing prerequisite packages (DKMS, build tools, kernel headers)..."
apt-get install -y dkms build-essential linux-headers-$(uname -r) ubuntu-drivers-common wget || {
    echo "Error: Failed to install one or more prerequisite packages (dkms, build-essential, etc)." >&2
    exit 1
}

# - dkms: for dynamic kernel module support, ensuring the NVIDIA module rebuilds on kernel updates.
# - build-essential, linux-headers-$(uname -r): needed if we have to compile the NVIDIA module (for DKMS or official installer).
# - ubuntu-drivers-common: provides the `ubuntu-drivers` tool for auto-detecting recommended drivers.
# - wget: used to download the NVIDIA .run installer if needed.

####### Determine Installation Mode (Desktop GUI or Headless) ########

# We will adjust the installation process depending on whether the system has a graphical desktop or is headless.
IS_HEADLESS=0
if [[ -z "${DISPLAY:-}" ]] && [[ -z "${XDG_SESSION_TYPE:-}" ]]; then
    IS_HEADLESS=1
else
    # If $DISPLAY is set or XDG_SESSION_TYPE indicates X11/Wayland, assume a desktop session is present.
    # (This might also catch cases where X is forwarded over SSH, but that's fine.)
    IS_HEADLESS=0
fi

if [[ $IS_HEADLESS -eq 1 ]]; then
    echo "Environment: No GUI detected (headless server mode). Will install headless NVIDIA driver components."
else
    echo "Environment: GUI session detected. Will install desktop NVIDIA driver components."
fi

####### NVIDIA Driver Installation via APT (Preferred) ########

echo "Detecting the recommended NVIDIA driver for the GPU via 'ubuntu-drivers'..."
# Use ubuntu-drivers to find the recommended driver package name.
UBU_DRIVERS_OUTPUT=$(ubuntu-drivers devices 2>/dev/null)
# The output usually contains lines like:
# "driver : nvidia-driver-XXX - distro non-free recommended"
# We will parse this to get the package name.
RECOMMENDED_DRIVER=""
if echo "$UBU_DRIVERS_OUTPUT" | grep -q "nvidia-driver-[0-9]\+"; then
    # Extract the first occurrence of an NVIDIA driver recommendation.
    RECOMMENDED_DRIVER=$(echo "$UBU_DRIVERS_OUTPUT" | awk '/nvidia-driver-[0-9].*recommended/{print $3; exit}')
    # The above uses awk to find the line with "recommended" and extract the third field (which should be the package name).
fi

if [[ -n "$RECOMMENDED_DRIVER" ]]; then
    echo "Recommended driver package: $RECOMMENDED_DRIVER (from Ubuntu repositories)"
else
    echo "No specific recommended driver was identified by ubuntu-drivers."
fi

# Determine the driver version number (branch) from the package name.
# e.g., "nvidia-driver-535" -> "535", or "nvidia-driver-535-server" -> "535".
DRIVER_BRANCH=""
if [[ -n "$RECOMMENDED_DRIVER" ]]; then
    DRIVER_BRANCH=$(echo "$RECOMMENDED_DRIVER" | sed -E 's/[^0-9]*([0-9]+).*/\1/')
fi

# If the system is headless, prefer the "-server" (data center) variant of the driver for stability and minimal X dependencies.
APT_PACKAGES=""
if [[ -n "$DRIVER_BRANCH" ]]; then
    if [[ $IS_HEADLESS -eq 1 ]]; then
        # Headless/server environment: use headless driver packages without X components.
        APT_PACKAGES="nvidia-headless-${DRIVER_BRANCH}-server nvidia-utils-${DRIVER_BRANCH}-server"
        # Include NVENC/NVDEC libraries for encoding/decoding support:
        APT_PACKAGES+=" libnvidia-encode-${DRIVER_BRANCH}-server libnvidia-decode-${DRIVER_BRANCH}-server"
        # We do not include nvidia-settings on a server (no GUI to run it).
    else
        # Desktop environment: use the standard driver package (which includes GUI support).
        APT_PACKAGES="${RECOMMENDED_DRIVER}"
        # Ensure we have the NVIDIA utility tools and settings for a desktop.
        APT_PACKAGES+=" nvidia-utils-${DRIVER_BRANCH}"
        APT_PACKAGES+=" nvidia-settings"
        # Include NVENC/NVDEC libraries (for video encoding/decoding) corresponding to the driver:
        APT_PACKAGES+=" libnvidia-encode-${DRIVER_BRANCH} libnvidia-decode-${DRIVER_BRANCH}"
    fi
fi

INSTALL_FROM_APT=true  # flag to indicate if apt method succeeds

if [[ -n "$APT_PACKAGES" ]]; then
    echo "Installing NVIDIA driver and NVENC/NVDEC support packages via apt: $APT_PACKAGES"
    # Perform the installation. This will install the driver and necessary components.
    # Using DEBIAN_FRONTEND=noninteractive to avoid any interactive prompts (like secure boot MOK).
    DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_PACKAGES
    if [[ $? -ne 0 ]]; then
        echo "APT installation failed or partially completed. Will attempt to use NVIDIA's official installer as a fallback." >&2
        INSTALL_FROM_APT=false
    fi
else
    # If no recommended driver was found or set (which is unusual), skip apt method.
    INSTALL_FROM_APT=false
fi

if [[ "$INSTALL_FROM_APT" = true ]]; then
    echo "NVIDIA driver installation via apt completed successfully."
    # If Secure Boot is enabled, the driver may not load until the user enrolls the key or disables Secure Boot.
    if [[ "$SECURE_BOOT" == "enabled" ]]; then
        echo "The driver was installed via apt with Secure Boot enabled."
        echo "If prompted on reboot, please enroll the MOK (Machine Owner Key) to allow the NVIDIA driver to load under Secure Boot."
    fi
else
    ####### NVIDIA Driver Installation via Official NVIDIA .run (Fallback) ########
    echo "Attempting installation via NVIDIA official installer (this may be used for newer GPUs or if apt failed)..."
    # Determine which driver version to download from NVIDIA.
    DRIVER_VERSION_FULL=""
    if [[ -n "$DRIVER_BRANCH" ]]; then
        # If we know the branch from recommended, try to get the exact version from apt candidate (for precision).
        candidate_ver=$(apt-cache policy "nvidia-driver-${DRIVER_BRANCH}" 2>/dev/null | awk '/Candidate:/ {print $2}')
        if [[ -n "$candidate_ver" ]]; then
            # The candidate version might look like "535.113.01-0ubuntu0.22.04.1"
            DRIVER_VERSION_FULL="${candidate_ver%%-*}"  # strip off the dash and beyond, leaving "535.113.01"
        fi
    fi
    # If we couldn't get a version from apt, choose a reliable default driver version for new hardware.
    if [[ -z "$DRIVER_VERSION_FULL" ]]; then
        # Choose a recent stable NVIDIA driver version (for example, 550 series for 2025).
        DRIVER_VERSION_FULL="550.144.03"
    fi

    echo "Selected NVIDIA driver version for download: $DRIVER_VERSION_FULL"
    NVIDIA_RUN_FILE="/tmp/NVIDIA-Linux-x86_64-${DRIVER_VERSION_FULL}.run"
    # Download the NVIDIA .run installer.
    echo "Downloading NVIDIA driver from official source..."
    wget -O "$NVIDIA_RUN_FILE" "https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION_FULL}/NVIDIA-Linux-x86_64-${DRIVER_VERSION_FULL}.run"
    if [[ $? -ne 0 ]]; then
        echo "Warning: Download of NVIDIA driver version $DRIVER_VERSION_FULL failed." >&2
        # Attempt a secondary fallback version if the first one is not available.
        if [[ "$DRIVER_VERSION_FULL" != "550.107.02" ]]; then
            DRIVER_VERSION_FULL="550.107.02"
            NVIDIA_RUN_FILE="/tmp/NVIDIA-Linux-x86_64-${DRIVER_VERSION_FULL}.run"
            echo "Attempting to download alternate driver version $DRIVER_VERSION_FULL..."
            wget -O "$NVIDIA_RUN_FILE" "https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION_FULL}/NVIDIA-Linux-x86_64-${DRIVER_VERSION_FULL}.run"
        fi
        if [[ $? -ne 0 ]]; then
            echo "Error: Could not download the NVIDIA driver installer from the official site." >&2
            echo "Please check your internet connection or manually download the driver .run file." >&2
            exit 1
        fi
    fi

    # Prepare to run the NVIDIA installer.
    # If running in a GUI, warn the user that installing with X running is not recommended.
    NVIDIA_INSTALL_ARGS="--silent --dkms"
    # --silent: run without interactive prompts.
    # --dkms: register the kernel module with DKMS for automatic rebuilds on kernel update.
    # (The installer will also handle blacklisting nouveau and other setup during installation.)
    if [[ $IS_HEADLESS -eq 0 ]]; then
        echo "NOTE: A graphical environment is active. Installing the NVIDIA driver with X11 running can cause a temporary display disruption."
        echo "It is recommended to quit the GUI and run this installer in text mode (runlevel 3)."
        read -rp "Proceed with the NVIDIA installer while in GUI? [y/N]: " CONTINUE_IN_GUI
        if [[ ! "$CONTINUE_IN_GUI" =~ ^[Yy]$ ]]; then
            echo "Installation aborted. Please run the script from a virtual console (CTRL+ALT+F3) or after stopping the display manager." >&2
            exit 1
        fi
        NVIDIA_INSTALL_ARGS+=" --no-x-check"  # override installer check for X.
    fi

    # Ensure nouveau is not loaded or will be disabled. The NVIDIA installer usually does this, but we double-check.
    if lsmod | grep -q "^nouveau"; then
        echo "Nouveau driver is currently loaded. Attempting to unload it and disable it..."
        # Try to unload nouveau kernel module.
        rmmod nouveau 2>/dev/null || echo "Warning: Could not unload nouveau module (it might be in use by the framebuffer)."
        # Blacklist nouveau to prevent it from loading on next boot.
        echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf
        update-initramfs -u || echo "Warning: Failed to update initramfs to blacklist nouveau."
    fi

    # If Secure Boot is on, inform user of manual steps since the official installer cannot sign modules.
    if [[ "$SECURE_BOOT" == "enabled" ]]; then
        echo "Secure Boot is enabled. The NVIDIA official installer cannot automatically sign the kernel module."
        echo "After installation, the driver module may be blocked by Secure Boot. You may need to disable Secure Boot or sign the module manually to use the NVIDIA driver."
    fi

    # Run the NVIDIA .run installer.
    echo "Running NVIDIA installer with options: $NVIDIA_INSTALL_ARGS"
    sh "$NVIDIA_RUN_FILE" $NVIDIA_INSTALL_ARGS
    if [[ $? -ne 0 ]]; then
        echo "Error: NVIDIA official installer encountered an error. Check the log for details." >&2
        exit 1
    fi

    echo "NVIDIA driver installation via official .run file completed successfully."
fi

####### Optional NVENC-Capable Software Installation ########

# At this point, the NVIDIA driver and NVENC libraries are installed.
# Now present an interactive menu for optional software that can utilize NVENC.
echo ""
echo "Optional Software Installation:"
echo "The following optional packages can be installed. These are applications that can utilize NVIDIA NVENC for video encoding:"
echo "  1) FFmpeg (command-line video transcoder with NVENC support)"
echo "  2) OBS Studio (broadcasting/recording software, uses NVENC for streaming) - requires a GUI"
echo "  3) HandBrake (video transcoder with NVENC support)"
echo "  4) None (skip optional software installation)"
echo ""
read -rp "Enter the numbers of the software to install (e.g., \"1 3\" for FFmpeg and HandBrake, or press Enter to skip): " USER_CHOICES

# Normalize input (separate by whitespace, remove commas if any).
USER_CHOICES=$(echo "$USER_CHOICES" | tr ',' ' ')
if [[ -z "$USER_CHOICES" ]]; then
    echo "No optional software selected. Skipping optional installations."
else
    # Use a loop to install each selected option.
    for choice in $USER_CHOICES; do
        case "$choice" in
            1)
                echo "Installing FFmpeg (with NVENC support)..."
                # Install FFmpeg. The version in Ubuntu's repository is typically built with NVENC support if the NVENC libraries are present.
                apt-get install -y ffmpeg && echo "FFmpeg installed successfully." || echo "Warning: FFmpeg installation failed."
                ;;
            2)
                echo "Installing OBS Studio (Open Broadcaster Software)..."
                if [[ $IS_HEADLESS -eq 1 ]]; then
                    echo "Skipping OBS Studio installation because no GUI is detected on this system."
                else
                    # OBS Studio is available in Ubuntu universe repository for recent versions.
                    # For older Ubuntu versions, we may add the OBS PPA for the latest version.
                    if ! apt-get install -y obs-studio; then
                        echo "OBS Studio not found in default repositories. Adding official OBS Studio PPA and trying again..."
                        apt-add-repository -y ppa:obsproject/obs-studio && apt-get update -y
                        apt-get install -y obs-studio && echo "OBS Studio installed successfully from PPA." || echo "Warning: OBS Studio installation failed."
                    else
                        echo "OBS Studio installed successfully."
                    fi
                fi
                ;;
            3)
                echo "Installing HandBrake video transcoder..."
                if [[ $IS_HEADLESS -eq 1 ]]; then
                    # On a server (no GUI), install just the CLI variant of HandBrake.
                    apt-get install -y handbrake-cli && echo "HandBrake CLI installed successfully." || echo "Warning: HandBrake CLI installation failed."
                else
                    # On a desktop, install the GUI and CLI.
                    apt-get install -y handbrake handbrake-cli && echo "HandBrake (GUI and CLI) installed successfully." || echo "Warning: HandBrake installation failed."
                fi
                ;;
            4)
                echo "Skipping optional software installation as per user choice."
                # If user explicitly chose "None", we break out of the loop and ignore other selections.
                break
                ;;
            *)
                echo "Warning: Invalid option '$choice' in selection. Skipping unrecognized choice."
                ;;
        esac
    done
fi

####### Completion and Reboot Prompt ########

echo ""
echo "=== Installation Complete ==="
echo "NVIDIA drivers and NVENC support have been installed."

# Advise on reboot if a driver was installed or updated.
# Typically, a reboot is needed for the new NVIDIA driver to take effect (especially if a kernel module was installed or nouveau was blacklisted).
NEED_REBOOT=1  # We assume a reboot is recommended after driver install.
# (We could refine this to check if the NVIDIA module is already loaded and functional, but it's safer to reboot in most cases.)

if [[ $NEED_REBOOT -eq 1 ]]; then
    if [[ "$SECURE_BOOT" == "enabled" ]]; then
        echo "Reminder: Secure Boot is enabled. If you installed the driver via apt, you may need to enroll the MOK after reboot to allow the driver to load."
    fi
    echo "A reboot is recommended for the changes to fully take effect (especially if this is the first time installing NVIDIA drivers on this system)."
    read -rp "Reboot now? [y/N]: " REBOOT_CHOICE
    if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
        echo "Rebooting system..."
        reboot
    else
        echo "Please reboot the system later to ensure the NVIDIA driver is properly initialized."
    fi
else
    echo "No reboot is required at this time."
fi

exit 0
