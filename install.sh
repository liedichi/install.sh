#!/bin/bash

# =============================================================================
# ARCH LINUX ZEN GAMING AUTO-INSTALL SCRIPT
# Optimized for: Intel i9-13900KS + RTX 4090 + 64GB RAM + Dual Monitors
# =============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

# Two-stage installer: Stage 1 (Live ISO) does disk partitioning and base install;
# Stage 2 (arch-chroot) completes system configuration and desktop setup
if [[ ! -f /etc/arch-release ]]; then
    log "Running Stage 1 (Live ISO): Disk partitioning and base install"

    if [[ -z "$INSTALL_DISK" ]]; then
        error "Environment variable INSTALL_DISK not set. Example: INSTALL_DISK=/dev/nvme0n1 bash install.sh"
    fi

    if [[ ! -b "$INSTALL_DISK" ]]; then
        error "Block device $INSTALL_DISK not found"
    fi

    timedatectl set-ntp true || true

    log "Wiping existing partition table on $INSTALL_DISK"
    wipefs -af "$INSTALL_DISK" || true
    sgdisk --zap-all "$INSTALL_DISK" || true

    log "Creating GPT partitions (1: EFI 1GiB, 2: root XFS)"
    sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:"EFI System" "$INSTALL_DISK"
    sgdisk -n 2:0:0     -t 2:8300 -c 2:"Arch Linux" "$INSTALL_DISK"

    PART_PREFIX="${INSTALL_DISK}"
    if [[ "$INSTALL_DISK" =~ nvme|mmcblk ]]; then
        EFI_PART="${INSTALL_DISK}p1"
        ROOT_PART="${INSTALL_DISK}p2"
    else
        EFI_PART="${INSTALL_DISK}1"
        ROOT_PART="${INSTALL_DISK}2"
    fi

    log "Formatting EFI ($EFI_PART) as FAT32 and ROOT ($ROOT_PART) as XFS"
    mkfs.fat -F32 "$EFI_PART"
    mkfs.xfs -f "$ROOT_PART"

    log "Mounting target filesystem"
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot

    log "Installing base system with linux-zen kernel"
    pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware networkmanager sudo neovim git efibootmgr

    log "Generating fstab"
    genfstab -U /mnt >> /mnt/etc/fstab
    # Optimize XFS mount for performance: switch relatime to noatime
    sed -i 's/relatime/noatime/g' /mnt/etc/fstab || true

    log "Copying installer into target and entering chroot (Stage 2)"
    install -Dm755 "$0" /mnt/root/install.sh
    arch-chroot /mnt /bin/bash /root/install.sh --stage2

    log "Stage 2 finished. You can now reboot."
    exit 0
fi

log "Starting Arch Linux Zen Gaming Auto-Install Script"

# =============================================================================
# SYSTEM CONFIGURATION
# =============================================================================

log "Configuring system settings..."

# Set hostname
echo "gaming-rig" > /etc/hostname

# Configure locale (United Kingdom)
cat > /etc/locale.gen << EOF
en_GB.UTF-8 UTF-8
EOF
locale-gen

# Set locale
echo "LANG=en_GB.UTF-8" > /etc/locale.conf

# Console keymap (UK)
echo "KEYMAP=uk" > /etc/vconsole.conf

# Configure timezone (UK)
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# =============================================================================
# BOOTLOADER CONFIGURATION
# =============================================================================

log "Configuring systemd-boot..."

# Install systemd-boot
bootctl install

# Detect root device and filesystem dynamically for boot entry
ROOT_DEVICE=$(findmnt -no SOURCE /)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_DEVICE")
ROOT_FSTYPE=$(findmnt -no FSTYPE /)

# Create bootloader configuration
cat > /boot/loader/loader.conf << EOF
timeout 0
default arch-linux-zen
editor no
EOF

# Create boot entry
cat > /boot/loader/entries/arch-linux-zen.conf << EOF
title Arch Linux Zen (Gaming)
linux /vmlinuz-linux-zen
initrd /intel-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=${ROOT_PARTUUID} rw rootfstype=${ROOT_FSTYPE} nvidia_drm.modeset=1 nvidia_drm.fbdev=1
EOF

# =============================================================================
# NETWORK CONFIGURATION
# =============================================================================

log "Configuring network..."

# Enable NetworkManager
systemctl enable NetworkManager.service

# =============================================================================
# USER CREATION
# =============================================================================

log "Creating user account..."

# Create gaming user
useradd -m -G wheel,audio,video,storage,power,network,optical,scanner,rfkill -s /bin/bash lied
echo "lied:625816" | chpasswd

# Configure sudo
echo "lied ALL=(ALL) ALL" >> /etc/sudoers

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================

log "Installing base packages..."

# Update package database
pacman -Syu --noconfirm

# Install essential packages
pacman -S --noconfirm \
    base-devel \
    linux-zen \
    linux-zen-headers \
    linux-firmware \
    intel-ucode \
    nvidia-dkms \
    nvidia-utils \
    lib32-nvidia-utils \
    nvidia-settings \
    wayland \
    wayland-protocols \
    xdg-utils \
    xdg-user-dirs \
    xdg-desktop-portal \
    xdg-desktop-portal-gtk \
    xdg-desktop-portal-hyprland \
    xorg-xwayland \
    hyprland \
    hyprpaper \
    hyprcursor \
    wl-clipboard \
    grim \
    slurp \
    swappy \
    wf-recorder \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    pipewire-jack \
    wireplumber \
    pavucontrol \
    networkmanager \t
    network-manager-applet \
    bluez \
    bluez-utils \
    blueman \
    polkit-gnome \
    sddm \
    firefox \
    discord \
    thunar \
    thunar-archive-plugin \
    file-roller \
    wofi \
    cliphist \
    hypridle \
    hyprlock \
    thunar-volman \
    tumbler \
    ffmpegthumbnailer \
    gvfs \
    gvfs-mtp \
    udisks2 \
    polkit \
    neovim \
    git \
    curl \
    wget \
    unzip \
    unrar \
    p7zip \
    rsync \
    htop \
    fastfetch \
    fzf \
    ripgrep \
    fd \
    bat \
    eza \
    tree \
    zsh \
    starship \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    ttf-jetbrains-mono-nerd \
    noto-fonts \
    noto-fonts-cjk \
    noto-fonts-emoji \
    ttf-dejavu \
    ttf-liberation \
    ttf-roboto \
    papirus-icon-theme \
    gtk3 \
    gtk4 \
    qt6-base \
    qt6-wayland \
    qt5-base \
    qt5-wayland \
    kvantum \
    gst-plugins-base \
    gst-plugins-good \
    gst-plugins-bad \
    gst-plugins-ugly \
    gst-libav \
    gst-vaapi \
    libva \
    libva-utils \
    vulkan-icd-loader \
    vulkan-tools \
    vulkan-nvidia \
    lib32-vulkan-icd-loader \
    lib32-vulkan-nvidia \
    steam \
    wine \
    wine-mono \
    wine-gecko \
    lutris \
    protontricks \
    gamemode \
    lib32-gamemode \
    mangohud \
    lib32-mangohud \
    vkbasalt \
    lib32-vkbasalt \
    gamescope \
    goverlay \
    obs-studio \
    nvtop \
    flatpak \
    ntfs-3g \
    nvme-cli \
    xfsprogs \
    btrfs-progs \
    dosfstools \
    cpupower \
    lm_sensors \
    thermald \
    irqbalance \
    zram-generator \
    avahi \
    nfs-utils

# Initialize XDG user directories for the user
runuser -l lied -c 'xdg-user-dirs-update'

# NVIDIA early KMS and initramfs modules for better Wayland experience
log "Configuring NVIDIA modules and initramfs..."
# Ensure mkinitcpio only builds default (no fallback) for linux-zen
if [ -f /etc/mkinitcpio.d/linux-zen.preset ]; then
  sed -i "s/^PRESETS=.*/PRESETS=('default')/" /etc/mkinitcpio.d/linux-zen.preset || true
  sed -i '/^fallback_/d' /etc/mkinitcpio.d/linux-zen.preset || true
fi
sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf || true
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf || true
echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'BL_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
BL_NOUVEAU
mkinitcpio -P

# Basic NVIDIA driver runtime tuning
cat > /etc/modprobe.d/nvidia-gaming.conf << 'NVIDIA_EOF'
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_UsePageAttributeTable=1
NVIDIA_EOF

# AUR helper (paru) - unattended
log "Installing paru (AUR helper) and AUR packages..."
pacman -S --needed --noconfirm git base-devel
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99_wheel_nopasswd
chmod 440 /etc/sudoers.d/99_wheel_nopasswd
runuser -l lied -c 'if [ ! -d "$HOME/.cache/paru/clone/paru" ]; then mkdir -p $HOME/.cache/paru/clone && cd $HOME/.cache/paru/clone && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si --noconfirm; fi'

# AUR packages for NVIDIA Wayland VA-API, theming, and gaming extras
runuser -l lied -c 'paru -S --needed --noconfirm \
  nvidia-vaapi-driver \
  dxvk-bin \
  dxvk-nvapi \
  heroic-games-launcher-bin \
  obs-vkcapture \
  ghostty-bin \
  openasar-bin \
  equicord \
  protonup-ng \
  catppuccin-ghostty-git \
  catppuccin-gtk-theme-mocha \
  catppuccin-kvantum-theme-git \
  catppuccin-cursors \
  catppuccin-sddm-theme-git'

# Flatpak setup and common apps
log "Configuring Flatpak and Flathub..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Proton-GE auto-setup for Steam using protonup-ng
runuser -l lied -c 'protonup -y -t GE-Proton --latest || true'

# Enable services
log "Enabling services..."
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable sddm.service
systemctl enable thermald.service
systemctl enable irqbalance.service || true
systemctl enable fstrim.timer
systemctl enable avahi-daemon.service
systemctl enable cpupower.service || true
systemctl enable nvidia-persistenced.service || true
systemctl enable nvidia-powerd.service || true

# Performance tuning
log "Applying performance tuning..."
cat > /etc/sysctl.d/99-gaming-tweaks.conf << 'SYSCTL_EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
kernel.sched_autogroup_enabled = 1
dev.i915.perf_stream_paranoid = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL_EOF

cat > /etc/default/cpupower << 'CPUPOWER_EOF'
governor="performance"
CPUPOWER_EOF

# ZRAM: use half of RAM, multiple devices
cat > /etc/systemd/zram-generator.conf << 'ZRAM_EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM_EOF

# NVMe scheduler and I/O tuning: none for NVMe, mq-deadline for SATA
cat > /etc/udev/rules.d/60-ioschedulers.rules << 'UDEV_EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
UDEV_EOF

# SDDM theming (Catppuccin) - try common theme IDs, fallback to default installed
mkdir -p /etc/sddm.conf.d
THEME_ID="catppuccin-mocha"
if [ ! -d "/usr/share/sddm/themes/$THEME_ID" ]; then
  if [ -d "/usr/share/sddm/themes/Catppuccin-Mocha" ]; then
    THEME_ID="Catppuccin-Mocha"
  fi
fi
cat > /etc/sddm.conf.d/theme.conf << SDDM_EOF
[Theme]
Current=$THEME_ID
SDDM_EOF

# GTK theming and icon/cursor themes for user
runuser -l lied -c 'mkdir -p $HOME/.config/gtk-3.0 $HOME/.config/gtk-4.0'
runuser -l lied -c 'cat > $HOME/.config/gtk-3.0/settings.ini <<\'GTK_EOF\''
[Settings]
gtk-theme-name=Catppuccin-Mocha-Standard-Blue-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Catppuccin-Mocha-Dark-Cursors
gtk-application-prefer-dark-theme=1
GTK_EOF
'
runuser -l lied -c 'ln -sf $HOME/.config/gtk-3.0/settings.ini $HOME/.config/gtk-4.0/settings.ini'

# Wayland/Electron/Firefox environment for user
runuser -l lied -c 'mkdir -p $HOME/.config/environment.d'
runuser -l lied -c 'cat > $HOME/.config/environment.d/wayland.conf <<\'ENV_EOF\''
MOZ_ENABLE_WAYLAND=1
MOZ_WEBRENDER=1
MOZ_DISABLE_RDD_SANDBOX=1
LIBVA_DRIVER_NAME=nvidia
ELECTRON_OZONE_PLATFORM_HINT=auto
DISCORD_FLAGS=--enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland
ENV_EOF
'

# Discord Wayland wrapper and desktop override
runuser -l lied -c 'mkdir -p $HOME/.local/bin $HOME/.local/share/applications'
runuser -l lied -c 'cat > $HOME/.local/bin/discord-wayland <<\'DISCORD_WRAPPER\''
#!/bin/bash
exec /usr/bin/discord --enable-features=UseOzonePlatform,WebRTCPipeWireCapturer,WaylandWindowDecorations --ozone-platform=wayland "$@"
DISCORD_WRAPPER
'
runuser -l lied -c 'chmod +x $HOME/.local/bin/discord-wayland'
runuser -l lied -c 'cat > $HOME/.local/share/applications/discord.desktop <<\'DISCORD_DESKTOP\''
[Desktop Entry]
Name=Discord
Comment=Discord (Wayland)
Exec=/home/lied/.local/bin/discord-wayland
Terminal=false
Type=Application
Icon=discord
Categories=Network;InstantMessaging;
StartupWMClass=discord
X-GNOME-UsesNotifications=true
DISCORD_DESKTOP
'

# Apply OpenAsar if available, and attempt Equicord injection if installed
runuser -l lied -c 'if command -v openasar >/dev/null 2>&1; then openasar -i || true; fi'
runuser -l lied -c 'if command -v equicord >/dev/null 2>&1; then equicord inject stable || true; fi'

# System Firefox policies to enable VA-API/Wayland friendly defaults
mkdir -p /usr/lib/firefox/distribution
cat > /usr/lib/firefox/distribution/policies.json << 'FFPOLICY_EOF'
{
  "policies": {
    "Preferences": {
      "media.ffmpeg.vaapi.enabled": true,
      "media.rdd-ffmpeg.enabled": true,
      "media.hardware-video-decoding.enabled": true,
      "media.hardware-video-decoding.force-enabled": true,
      "widget.dmabuf.force-enabled": true,
      "gfx.webrender.all": true,
      "layers.acceleration.force-enabled": true,
      "gfx.x11-egl.force-enabled": true,
      "gfx.webrender.precache-shaders": true,
      "widget.use-xdg-desktop-portal.file-picker": 1,
      "widget.use-xdg-desktop-portal": 1
    }
  }
}
FFPOLICY_EOF

# Qt theming via Kvantum and qt[5|6]ct
pacman -S --needed --noconfirm qt6ct qt5ct
runuser -l lied -c 'mkdir -p $HOME/.config && echo "[General]\nicon_theme=Papirus-Dark" > $HOME/.config/qt6ct.conf'
runuser -l lied -c 'mkdir -p $HOME/.config && echo "[General]\nicon_theme=Papirus-Dark" > $HOME/.config/qt5ct.conf'
runuser -l lied -c 'mkdir -p $HOME/.config/Kvantum && echo -e "[General]\ntheme=Catppuccin-Mocha" > $HOME/.config/Kvantum/kvantum.kvconfig'

# Hyprland configuration with animations and wallpaper
log "Creating Hyprland configuration..."
runuser -l lied -c 'mkdir -p $HOME/.config/hypr $HOME/Pictures/Wallpapers'
runuser -l lied -c 'curl -fsSL -o $HOME/Pictures/Wallpapers/anime-dark-1.jpg https://images.unsplash.com/photo-1519681393784-d120267933ba?q=80&w=2560&auto=format&fit=crop'
runuser -l lied -c 'cat > $HOME/.config/hypr/hyprpaper.conf <<\'HPAPER_EOF\''
preload = ~/Pictures/Wallpapers/anime-dark-1.jpg
wallpaper = ,~/Pictures/Wallpapers/anime-dark-1.jpg
HPAPER_EOF
'
runuser -l lied -c 'cat > $HOME/.config/hypr/hyprland.conf <<\'HYPR_EOF\''
monitor=,preferred,auto,1

env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = QT_QPA_PLATFORM,wayland
env = QT_QPA_PLATFORMTHEME,qt6ct
env = QT_STYLE_OVERRIDE,Kvantum
env = QT_WAYLAND_DISABLE_WINDOWDECORATION,1
env = GDK_BACKEND,wayland
env = MOZ_ENABLE_WAYLAND,1
env = __GL_GSYNC_ALLOWED,1
env = __GL_VRR_ALLOWED,1
# Prefer GBM on newer NVIDIA drivers; fallback safe
env = GBM_BACKEND,nvidia-drm
# Uncomment if you see cursor corruption on NVIDIA
# env = WLR_NO_HARDWARE_CURSORS,1

input {
    kb_layout = gb
    follow_mouse = 1
    touchpad {
        natural_scroll = true
    }
    sensitivity = 0
    accel_profile = flat
}

general {
    gaps_in = 8
    gaps_out = 16
    border_size = 3
    col.active_border = rgba(89b4faee) rgba(74c7ecaa) 45deg
    col.inactive_border = rgba(181825aa)
    layout = master
}

decoration {
    rounding = 12
    blur {
        enabled = true
        size = 8
        passes = 2
        noise = 0.02
      }
    drop_shadow = true
    shadow_range = 20
    shadow_render_power = 3
}

animations {
    enabled = true
    bezier = smooth, 0.05, 0.9, 0.1, 1.0
    animation = windows, 1, 6, smooth, slide
    animation = border, 1, 10, smooth
    animation = fade, 1, 6, smooth
    animation = workspaces, 1, 5, smooth, slide
}

exec-once = hyprpaper
exec-once = hypridle
exec-once = nm-applet --indicator
exec-once = blueman-applet
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = fastfetch

bind = SUPER, Return, exec, ghostty
bind = SUPER, C, killactive,
bind = SUPER, M, exit,
bind = SUPER, E, exec, thunar
bind = SUPER, Q, exec, firefox
bind = SUPER, W, exec, firefox --private-window
bind = SUPER, S, togglefloating,
bind = SUPER, F, fullscreen,
bind = SUPER, V, exec, cliphist list | wofi --dmenu | wl-copy

HYPR_EOF
'

# Ghostty configuration
runuser -l lied -c 'mkdir -p $HOME/.config/ghostty'
runuser -l lied -c 'cat > $HOME/.config/ghostty/config <<\'GHOSTTY_EOF\''
font-family = JetBrainsMono Nerd Font
font-size = 12
cursor-style = beam
window-padding-x = 10
window-padding-y = 10
theme = Catppuccin-Mocha
shell-integration = zsh
GHOSTTY_EOF
'

# Zsh configuration with autocomplete and syntax highlighting
runuser -l lied -c 'cat > $HOME/.zshrc <<\'ZSHRC_EOF\''
export ZDOTDIR="$HOME"
export EDITOR=nvim

# Use modern completion and history
autoload -Uz compinit && compinit
setopt AUTO_MENU AUTO_LIST COMPLETE_IN_WORD
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE EXTENDED_HISTORY
HISTSIZE=100000
SAVEHIST=100000
HISTFILE=$HOME/.zsh_history

# Plugins
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
[ -f /usr/share/fzf/completion.zsh ] && source /usr/share/fzf/completion.zsh

# Prompt
eval "$(starship init zsh)"

# Aliases
alias ls="eza --icons=auto --group-directories-first"
alias ll="ls -alh"
alias cat="bat --paging=never"
alias grep="rg"
ZSHRC_EOF
'

# MangoHud default configuration
runuser -l lied -c 'mkdir -p $HOME/.config/MangoHud'
runuser -l lied -c 'cat > $HOME/.config/MangoHud/MangoHud.conf <<\'MH_EOF\''
fps
frametime
gpu_temp
cpu_temp
gpu_core_clock
cpu_mhz
gpu_text=GPU
cpu_text=CPU
arch
vram
ram
engine_version
vulkan_driver
position=top-right
background_alpha=0.3
font_size=22
toggle_hud=Shift_R+F12
MH_EOF
'

# vkBasalt example config and instructions
runuser -l lied -c 'mkdir -p $HOME/.config/vkBasalt'
runuser -l lied -c 'cat > $HOME/.config/vkBasalt/vkBasalt.conf <<\'VKB_EOF\''
# Enable a subtle sharpening by default; enable per-game via launch options
effects = cas
casSharpness = 0.2
VKB_EOF
'

# Make zsh default shell for user
chsh -s /bin/zsh lied || true

# Remove temporary NOPASSWD rule for wheel to restore security
rm -f /etc/sudoers.d/99_wheel_nopasswd || true

log "All tasks completed. You can now reboot into your optimized Hyprland gaming setup."