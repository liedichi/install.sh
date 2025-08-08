#!/bin/bash
# =============================================================================
# ARCH LINUX ZEN GAMING AUTO-INSTALL SCRIPT
# Optimized for: Intel i9-13900KS + RTX 4090 + 64GB RAM + Dual Monitors
# =============================================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Failed at line $LINENO"; exit 1' ERR

# ---- Colors ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---- Logging + warning counter ----
WARNINGS=0
log()  { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; ((WARNINGS++)); }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---- Stage selection (explicit flag preferred; fallback auto-detect) ----
MODE=""
case "${1:-}" in
  --stage1) MODE=stage1; shift ;;
  --stage2) MODE=stage2; shift ;;
esac
if [[ -z "$MODE" ]]; then
  if [[ -d /run/archiso ]]; then MODE=stage1; else MODE=stage2; fi
fi

# ---- Per-stage logging ----
if [[ "$MODE" == "stage1" ]]; then
  LOGFILE="/root/arch-install.log"           # lives in ISO RAM
  exec > >(tee -a "$LOGFILE") 2>&1
else
  LOGFILE="/var/log/installer.log"           # persists after install
  mkdir -p "$(dirname "$LOGFILE")"
  exec > >(tee -a "$LOGFILE") 2>&1
fi

# =============================================================================
# STAGE 1 (Live ISO): partition, format, mount, base install, chroot -> Stage 2
# =============================================================================
if [[ "$MODE" == "stage1" ]]; then
  log "Running Stage 1 (Live ISO): Disk partitioning and base install"

  [[ -n "${INSTALL_DISK:-}" ]] || die "Set INSTALL_DISK (e.g. INSTALL_DISK=/dev/nvme0n1)"
  [[ -b "$INSTALL_DISK"      ]] || die "Block device $INSTALL_DISK not found"

  timedatectl set-ntp true || true

  log "Wiping existing partition table on $INSTALL_DISK"
  wipefs -af "$INSTALL_DISK" || true
  sgdisk --zap-all "$INSTALL_DISK" || true

  log "Creating GPT: 1) EFI 1GiB (ef00)  2) ROOT XFS (8300)"
  sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:"EFI System" "$INSTALL_DISK"
  sgdisk -n 2:0:0     -t 2:8300 -c 2:"Arch Linux" "$INSTALL_DISK"

  if [[ "$INSTALL_DISK" =~ nvme|mmcblk ]]; then
    EFI_PART="${INSTALL_DISK}p1"; ROOT_PART="${INSTALL_DISK}p2"
  else
    EFI_PART="${INSTALL_DISK}1";  ROOT_PART="${INSTALL_DISK}2"
  fi

  log "Formatting EFI ($EFI_PART) as FAT32 and ROOT ($ROOT_PART) as XFS"
  mkfs.fat -F32 "$EFI_PART"
  mkfs.xfs -f "$ROOT_PART"

  log "Mounting target filesystem"
  mount "$ROOT_PART" /mnt
  mkdir -p /mnt/boot
  mount "$EFI_PART" /mnt/boot

  log "Installing base system with linux-zen kernel"
  pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
    networkmanager sudo neovim git efibootmgr

  log "Generating fstab (switch relatime -> noatime)"
  genfstab -U /mnt >> /mnt/etc/fstab
  sed -i 's/\<relatime\>/noatime/g' /mnt/etc/fstab || true

  # Persist Stage 1 log into target so the final log is continuous
  mkdir -p /mnt/var/log
  cp -f "$LOGFILE" /mnt/var/log/installer.log || true

  log "Copying installer into target and entering chroot (Stage 2)"
  cat "$0" > /mnt/root/install.sh
  chmod +x /mnt/root/install.sh

  # Run the file directly so functions are available in Stage 2
  arch-chroot /mnt /bin/bash /root/install.sh --stage2

  # Stage 2 does the summary & reboot prompt. We're done here.
  exit 0
fi

# =============================================================================
# STAGE 2 (in chroot): system config, packages, NVIDIA, desktop, finalize
# =============================================================================
log "Starting Arch Linux Zen Gaming Auto-Install Script (Stage 2)"

# ---- System settings ----
log "Configuring hostname, locale, timezone, console..."
echo "gaming-rig" > /etc/hostname

cat > /etc/locale.gen <<'EOF'
en_GB.UTF-8 UTF-8
EOF
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "KEYMAP=uk" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# ---- Bootloader (systemd-boot) ----
log "Installing systemd-boot..."
bootctl install
ROOT_DEVICE="$(findmnt -no SOURCE /)"
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOT_DEVICE")"
ROOT_FSTYPE="$(findmnt -no FSTYPE /)"

cat > /boot/loader/loader.conf <<'EOF'
timeout 0
default arch-linux-zen
editor no
EOF

cat > /boot/loader/entries/arch-linux-zen.conf <<EOF
title Arch Linux Zen (Gaming)
linux /vmlinuz-linux-zen
initrd /intel-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=${ROOT_PARTUUID} rw rootfstype=${ROOT_FSTYPE} nvidia_drm.modeset=1 nvidia_drm.fbdev=1
EOF

# ---- Network ----
log "Enabling NetworkManager..."
systemctl enable NetworkManager.service

# ---- User creation (interactive password) ----
log "Creating user 'lied' and setting password..."
id -u lied &>/dev/null || useradd -m -G wheel,audio,video,storage,power,network,optical,scanner,rfkill -s /bin/bash lied

while :; do
  echo
  read -rs -p "Set password for user 'lied': " _PW1; echo
  read -rs -p "Confirm password for user 'lied': " _PW2; echo
  if [[ "$_PW1" == "$_PW2" && -n "$_PW1" ]]; then
    printf 'lied:%s\n' "$_PW1" | chpasswd
    unset _PW1 _PW2
    break
  else
    echo "Passwords did not match or were empty. Try again."
  fi
done

echo "lied ALL=(ALL) ALL" >> /etc/sudoers

echo
read -rp "Set a root password? [y/N] " _ans_root
if [[ "$_ans_root" =~ ^[Yy]$ ]]; then
  passwd root
else
  passwd -l root
  warn "Root account locked (sudo recommended)."
fi

# ---- Packages (repo) ----
log "Syncing and installing packages..."
pacman -Syu --noconfirm
pacman -S --noconfirm \
  base-devel \
  linux-zen linux-zen-headers linux-firmware intel-ucode \
  nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
  wayland wayland-protocols xdg-utils xdg-user-dirs \
  xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland \
  xorg-xwayland hyprland hyprpaper hyprcursor \
  wl-clipboard grim slurp swappy wf-recorder \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
  networkmanager \
  network-manager-applet \
  bluez bluez-utils blueman \
  polkit-gnome sddm \
  firefox discord \
  thunar thunar-archive-plugin file-roller \
  wofi cliphist hypridle hyprlock \
  thunar-volman tumbler ffmpegthumbnailer gvfs gvfs-mtp udisks2 polkit \
  neovim git curl wget unzip unrar p7zip rsync htop fastfetch fzf ripgrep fd bat eza tree \
  zsh starship zsh-autosuggestions zsh-syntax-highlighting \
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-roboto \
  papirus-icon-theme gtk3 gtk4 qt6-base qt6-wayland qt5-base qt5-wayland kvantum \
  gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav \
  gst-vaapi libva libva-utils vulkan-icd-loader vulkan-tools vulkan-nvidia \
  lib32-vulkan-icd-loader lib32-vulkan-nvidia \
  steam wine wine-mono wine-gecko lutris protontricks gamemode lib32-gamemode \
  mangohud lib32-mangohud vkbasalt lib32-vkbasalt gamescope goverlay obs-studio nvtop \
  flatpak ntfs-3g nvme-cli xfsprogs btrfs-progs dosfstools \
  cpupower lm_sensors thermald irqbalance zram-generator avahi nfs-utils

runuser -l lied -c 'xdg-user-dirs-update'

# ---- NVIDIA early KMS + initramfs + runtime tweaks ----
log "Configuring NVIDIA KMS and initramfs..."
if [[ -f /etc/mkinitcpio.d/linux-zen.preset ]]; then
  sed -i "s/^PRESETS=.*/PRESETS=('default')/" /etc/mkinitcpio.d/linux-zen.preset || true
  sed -i '/^fallback_/d' /etc/mkinitcpio.d/linux-zen.preset || true
fi
sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf || true
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf || true
echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'BL_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
BL_NOUVEAU
mkinitcpio -P

cat > /etc/modprobe.d/nvidia-gaming.conf <<'NVIDIA_EOF'
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_UsePageAttributeTable=1
NVIDIA_EOF

# ---- Paru (AUR) + AUR packages ----
log "Installing paru and AUR packages..."
pacman -S --needed --noconfirm git base-devel
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99_wheel_nopasswd
chmod 440 /etc/sudoers.d/99_wheel_nopasswd

runuser -l lied -c 'if [ ! -d "$HOME/.cache/paru/clone/paru" ]; then mkdir -p $HOME/.cache/paru/clone && cd $HOME/.cache/paru/clone && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si --noconfirm; fi'
runuser -l lied -c 'paru -S --needed --noconfirm nvidia-vaapi-driver dxvk-bin dxvk-nvapi heroic-games-launcher-bin obs-vkcapture ghostty-bin openasar-bin equicord protonup-ng catppuccin-ghostty-git catppuccin-gtk-theme-mocha catppuccin-kvantum-theme-git catppuccin-cursors catppuccin-sddm-theme-git'

# ---- Flatpak + Proton-GE ----
log "Configuring Flathub and Proton-GE..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
runuser -l lied -c 'protonup -y -t GE-Proton --latest || true'

# ---- Services ----
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

# ---- Performance tuning ----
log "Applying kernel/sysctl/IO tuning..."
cat > /etc/sysctl.d/99-gaming-tweaks.conf <<'SYSCTL_EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
kernel.sched_autogroup_enabled = 1
dev.i915.perf_stream_paranoid = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL_EOF

cat > /etc/default/cpupower <<'CPUPOWER_EOF'
governor="performance"
CPUPOWER_EOF

cat > /etc/systemd/zram-generator.conf <<'ZRAM_EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM_EOF

cat > /etc/udev/rules.d/60-ioschedulers.rules <<'UDEV_EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
UDEV_EOF

# ---- SDDM theme (with fallbacks) ----
mkdir -p /etc/sddm.conf.d
THEME_ID="catppuccin-mocha"
if [[ ! -d "/usr/share/sddm/themes/$THEME_ID" ]]; then
  if [[ -d "/usr/share/sddm/themes/Catppuccin-Mocha" ]]; then THEME_ID="Catppuccin-Mocha"; else THEME_ID="elarun"; fi
fi
cat > /etc/sddm.conf.d/theme.conf <<SDDM_EOF
[Theme]
Current=$THEME_ID
SDDM_EOF

# ---- User theming / env / Discord wrapper ----
runuser -l lied -c 'mkdir -p $HOME/.config/gtk-3.0 $HOME/.config/gtk-4.0'
runuser -l lied -c 'cat > $HOME/.config/gtk-3.0/settings.ini <<'"'"'GTK_EOF'"'"'
[Settings]
gtk-theme-name=Catppuccin-Mocha-Standard-Blue-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Catppuccin-Mocha-Dark-Cursors
gtk-application-prefer-dark-theme=1
GTK_EOF
'
runuser -l lied -c 'ln -sf $HOME/.config/gtk-3.0/settings.ini $HOME/.config/gtk-4.0/settings.ini'

runuser -l lied -c 'mkdir -p $HOME/.config/environment.d'
runuser -l lied -c 'cat > $HOME/.config/environment.d/wayland.conf <<'"'"'ENV_EOF'"'"'
MOZ_ENABLE_WAYLAND=1
MOZ_WEBRENDER=1
MOZ_DISABLE_RDD_SANDBOX=1
LIBVA_DRIVER_NAME=nvidia
ELECTRON_OZONE_PLATFORM_HINT=auto
DISCORD_FLAGS=--enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland
ENV_EOF
'

runuser -l lied -c 'mkdir -p $HOME/.local/bin $HOME/.local/share/applications'
runuser -l lied -c 'cat > $HOME/.local/bin/discord-wayland <<'"'"'DISCORD_WRAPPER'"'"'
#!/bin/bash
exec /usr/bin/discord --enable-features=UseOzonePlatform,WebRTCPipeWireCapturer,WaylandWindowDecorations --ozone-platform=wayland "$@"
DISCORD_WRAPPER
'
runuser -l lied -c 'chmod +x $HOME/.local/bin/discord-wayland'
runuser -l lied -c 'cat > $HOME/.local/share/applications/discord.desktop <<'"'"'DISCORD_DESKTOP'"'"'
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

# ---- Firefox system policies ----
mkdir -p /usr/lib/firefox/distribution
cat > /usr/lib/firefox/distribution/policies.json <<'FFPOLICY_EOF'
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

# ---- Qt theming ----
pacman -S --needed --noconfirm qt6ct qt5ct
runuser -l lied -c 'mkdir -p $HOME/.config && echo "[General]\nicon_theme=Papirus-Dark" > $HOME/.config/qt6ct.conf'
runuser -l lied -c 'mkdir -p $HOME/.config && echo "[General]\nicon_theme=Papirus-Dark" > $HOME/.config/qt5ct.conf'
runuser -l lied -c 'mkdir -p $HOME/.config/Kvantum && echo -e "[General]\ntheme=Catppuccin-Mocha" > $HOME/.config/Kvantum/kvantum.kvconfig'

# ---- Hyprland config ----
log "Creating Hyprland configuration..."
runuser -l lied -c 'mkdir -p $HOME/.config/hypr $HOME/Pictures/Wallpapers'
runuser -l lied -c 'curl -fsSL -o $HOME/Pictures/Wallpapers/anime-dark-1.jpg https://images.unsplash.com/photo-1519681393784-d120267933ba?q=80&w=2560&auto=format&fit=crop'
runuser -l lied -c 'cat > $HOME/.config/hypr/hyprpaper.conf <<'"'"'HPAPER_EOF'"'"'
preload = ~/Pictures/Wallpapers/anime-dark-1.jpg
wallpaper = ,~/Pictures/Wallpapers/anime-dark-1.jpg
HPAPER_EOF
'
runuser -l lied -c 'cat > $HOME/.config/hypr/hyprland.conf <<'"'"'HYPR_EOF'"'"'
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
env = GBM_BACKEND,nvidia-drm
# env = WLR_NO_HARDWARE_CURSORS,1  # uncomment if you see cursor issues

input {
    kb_layout = gb
    follow_mouse = 1
    touchpad { natural_scroll = true }
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

# ---- Ghostty ----
runuser -l lied -c 'mkdir -p $HOME/.config/ghostty'
runuser -l lied -c 'cat > $HOME/.config/ghostty/config <<'"'"'GHOSTTY_EOF'"'"'
font-family = JetBrainsMono Nerd Font
font-size = 12
cursor-style = beam
window-padding-x = 10
window-padding-y = 10
theme = Catppuccin-Mocha
shell-integration = zsh
GHOSTTY_EOF
'

# ---- Zsh ----
runuser -l lied -c 'cat > $HOME/.zshrc <<'"'"'ZSHRC_EOF'"'"'
export ZDOTDIR="$HOME"
export EDITOR=nvim
autoload -Uz compinit && compinit
setopt AUTO_MENU AUTO_LIST COMPLETE_IN_WORD
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE EXTENDED_HISTORY
HISTSIZE=100000
SAVEHIST=100000
HISTFILE=$HOME/.zsh_history
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
[ -f /usr/share/fzf/completion.zsh ] && source /usr/share/fzf/completion.zsh
eval "$(starship init zsh)"
alias ls="eza --icons=auto --group-directories-first"
alias ll="ls -alh"
alias cat="bat --paging=never"
alias grep="rg"
ZSHRC_EOF
'

# ---- MangoHud ----
runuser -l lied -c 'mkdir -p $HOME/.config/MangoHud'
runuser -l lied -c 'cat > $HOME/.config/MangoHud/MangoHud.conf <<'"'"'MH_EOF'"'"'
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

# ---- vkBasalt ----
runuser -l lied -c 'mkdir -p $HOME/.config/vkBasalt'
runuser -l lied -c 'cat > $HOME/.config/vkBasalt/vkBasalt.conf <<'"'"'VKB_EOF'"'"'
effects = cas
casSharpness = 0.2
VKB_EOF
'

# ---- Default shell (guarded) ----
if [[ -x /bin/zsh ]]; then
  chsh -s /bin/zsh lied || warn "Could not set zsh as default shell (non-fatal)."
else
  warn "zsh not found at /bin/zsh; skipping chsh."
fi

# ---- Cleanup sudoers temp ----
rm -f /etc/sudoers.d/99_wheel_nopasswd || true

# ---- NVIDIA quick sanity check ----
verify_nvidia() {
  echo
  echo "[NV] Verifying NVIDIA driver…"
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi not found. Driver may not be installed."
    return
  fi
  if ! nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi failed to run. Check DKMS build/logs."
  else
    log "nvidia-smi OK — driver loaded."
  fi
  if ! lsmod | grep -q '^nvidia'; then
    warn "nvidia kernel module not loaded."
  fi
  if ! grep -q 'nvidia_drm.modeset=1' /proc/cmdline 2>/dev/null; then
    warn "kernel cmdline missing nvidia_drm.modeset=1 (KMS)."
  fi
}
verify_nvidia

# ---- Final summary + reboot prompt ----
echo
echo "========================================"
echo "Logs saved to: $LOGFILE"
if [[ "$WARNINGS" -gt 0 ]]; then
  echo -e "⚠  ${YELLOW}Installation completed with $WARNINGS warning(s).${NC}"
  echo -e "   Review [WARN] lines above before rebooting."
else
  echo -e "✅ ${GREEN}Installation completed successfully with no warnings.${NC}"
fi
echo "========================================"
echo
read -rp "Press Y to reboot now, or any other key to stay in shell: " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  log "Rebooting..."
  reboot
else
  log "You chose not to reboot. You can manually reboot later."
fi
