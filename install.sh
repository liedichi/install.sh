#!/bin/bash
# ============================================================
# Arch Linux ZEN Gaming Auto-Installer — single-file version
# ============================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Failed at line $LINENO"; exit 1' ERR

# ---------- helpers (self-healing) ----------
ensure_helpers() {
  : "${RED:='\033[0;31m'}" "${GREEN:='\033[0;32m'}" "${YELLOW:='\033[1;33m'}" "${BLUE:='\033[0;34m'}" "${NC:='\033[0m'}"
  : "${WARNINGS:=0}"
  type log  >/dev/null 2>&1 || eval 'log(){ echo -e "'"$GREEN"'["$(date +%F" "%T)"]'"$NC"' $*"; }'
  type warn >/dev/null 2>&1 || eval 'warn(){ echo -e "'"$YELLOW"'[WARN]'"$NC"' $*"; : $((WARNINGS++)); }'
  type die  >/dev/null 2>&1 || eval 'die(){ echo -e "'"$RED"'[ERROR]'"$NC"' $*" 1>&2; exit 1; }'
}
ensure_helpers

# ---------- require root ----------
if [[ $EUID -ne 0 ]]; then die "Run as root (sudo)."; fi

# ---------- stage detect ----------
IN_ISO=$([ -d /run/archiso ] && echo 1 || echo 0)
IN_INSTALLED=$([ -f /etc/arch-release ] && echo 1 || echo 0)

# ---------- logging ----------
if [[ "$IN_ISO" == 1 && "$IN_INSTALLED" == 0 ]]; then
  LOGFILE="/root/arch-install.log"
else
  LOGFILE="/var/log/installer.log"; mkdir -p /var/log || true
fi
exec > >(tee -a "$LOGFILE") 2>&1

# ============================================================
# STAGE A (ISO): partition + base install → chroot and re-run
# ============================================================
if [[ "$IN_ISO" == 1 && "$IN_INSTALLED" == 0 ]]; then
  log "Running on Arch ISO — Stage A (partition + base install)."

  [[ -n "${INSTALL_DISK:-}" ]] || die "Set INSTALL_DISK (e.g. INSTALL_DISK=/dev/nvme0n1)."
  [[ -b "$INSTALL_DISK"      ]] || die "Block device $INSTALL_DISK not found."
  timedatectl set-ntp true || true

  log "Wiping $INSTALL_DISK"
  wipefs -af "$INSTALL_DISK" || true
  sgdisk --zap-all "$INSTALL_DISK" || true

  log "Creating partitions: 1GiB EFI + XFS root"
  sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:"EFI System" "$INSTALL_DISK"
  sgdisk -n 2:0:0     -t 2:8300 -c 2:"Arch Linux" "$INSTALL_DISK"

  if [[ "$INSTALL_DISK" =~ nvme|mmcblk ]]; then
    EFI_PART="${INSTALL_DISK}p1"; ROOT_PART="${INSTALL_DISK}p2"
  else
    EFI_PART="${INSTALL_DISK}1";  ROOT_PART="${INSTALL_DISK}2"
  fi

  log "Formatting filesystems"
  mkfs.fat -F32 "$EFI_PART"
  mkfs.xfs -f "$ROOT_PART"

  log "Mounting target"
  mount "$ROOT_PART" /mnt
  mkdir -p /mnt/boot
  mount "$EFI_PART" /mnt/boot

  log "Pacstrap base + linux-zen"
  pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
    networkmanager sudo neovim git efibootmgr

  log "Generating fstab (noatime)"
  genfstab -U /mnt >> /mnt/etc/fstab
  sed -i 's/\<relatime\>/noatime/g' /mnt/etc/fstab || true

  # persist log + copy script
  mkdir -p /mnt/var/log
  cp -f "$LOGFILE" /mnt/var/log/installer.log || true
  install -Dm755 "$0" /mnt/root/install.sh

  log "Chrooting to continue (Stage B)…"
  arch-chroot /mnt /bin/bash /root/install.sh

  exit 0
fi

# ============================================================
# STAGE B (inside chroot): configure + desktop + finalize
# ============================================================
ensure_helpers
log "Inside target system — Stage B (configure + desktop)."

# ---------- system basics ----------
echo "gaming-rig" > /etc/hostname

cat > /etc/locale.gen <<'EOF'
en_GB.UTF-8 UTF-8
EOF
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "KEYMAP=uk" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# ---------- network ----------
systemctl enable NetworkManager.service

# ---------- user + passwords (interactive) ----------
log "Creating user 'lied' and setting password"
id -u lied &>/dev/null || useradd -m -G wheel,audio,video,storage,power,network,optical,scanner,rfkill -s /bin/bash lied
while :; do
  echo
  read -rs -p "Set password for user 'lied': " p1; echo
  read -rs -p "Confirm password for user 'lied': " p2; echo
  [[ -n "$p1" && "$p1" == "$p2" ]] && { printf 'lied:%s\n' "$p1" | chpasswd; unset p1 p2; break; }
  echo "Passwords did not match or were empty. Try again."
done
echo "lied ALL=(ALL) ALL" >> /etc/sudoers
echo
read -rp "Set a root password? [y/N] " setroot
if [[ "$setroot" =~ ^[Yy]$ ]]; then
  passwd root
else
  passwd -l root
  warn "Root account locked; use sudo."
fi

# ---------- packages ----------
log "Updating + installing desktop/gaming stack"
pacman -Syu --noconfirm
pacman -S --noconfirm \
  base-devel linux-zen linux-zen-headers linux-firmware intel-ucode \
  nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
  wayland wayland-protocols xdg-utils xdg-user-dirs \
  xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland \
  xorg-xwayland hyprland hyprpaper hyprcursor \
  wl-clipboard grim slurp swappy wf-recorder \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
  networkmanager network-manager-applet \
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

# ---------- NVIDIA KMS + initramfs ----------
log "Configuring NVIDIA early KMS + initramfs"
if [[ -f /etc/mkinitcpio.d/linux-zen.preset ]]; then
  sed -i "s/^PRESETS=.*/PRESETS=('default')/" /etc/mkinitcpio.d/linux-zen.preset || true
  sed -i '/^fallback/d' /etc/mkinitcpio.d/linux-zen.preset || true
fi
sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf || true
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf || true
echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'BL_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
BL_NOUVEAU

# rebuild initramfs (default only) + remove any fallback image
mkinitcpio -P
rm -f /boot/initramfs-linux-zen-fallback.img || true

# ---------- Bootloader AFTER initramfs exists ----------
log "Installing systemd-boot and writing entry..."
bootctl install || true

ROOT_DEV="$(findmnt -no SOURCE /)"
ROOT_UUID="$(blkid -s PARTUUID -o value "$ROOT_DEV")"
ROOT_FS="$(findmnt -no FSTYPE /)"

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
options root=PARTUUID=${ROOT_UUID} rw rootfstype=${ROOT_FS} nvidia_drm.modeset=1 nvidia_drm.fbdev=1
EOF

# sanity: required files must exist
for f in /boot/vmlinuz-linux-zen /boot/initramfs-linux-zen.img /boot/intel-ucode.img; do
  [[ -f "$f" ]] || die "Missing $f — kernel/initramfs/microcode not in place."
done
bootctl update || true

# ---------- Runtime NV tweaks ----------
cat > /etc/modprobe.d/nvidia-gaming.conf <<'EOF'
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_UsePageAttributeTable=1
EOF

# ---------- AUR helper + AUR apps ----------
log "Installing paru + AUR packages"
pacman -S --needed --noconfirm git base-devel
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99_wheel_nopasswd
chmod 440 /etc/sudoers.d/99_wheel_nopasswd
runuser -l lied -c 'if [ ! -d "$HOME/.cache/paru/clone/paru" ]; then mkdir -p $HOME/.cache/paru/clone && cd $HOME/.cache/paru/clone && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si --noconfirm; fi'
runuser -l lied -c 'paru -S --needed --noconfirm nvidia-vaapi-driver dxvk-bin dxvk-nvapi heroic-games-launcher-bin obs-vkcapture ghostty-bin openasar-bin equicord protonup-ng catppuccin-ghostty-git catppuccin-gtk-theme-mocha catppuccin-kvantum-theme-git catppuccin-cursors catppuccin-sddm-theme-git'

# ---------- Flatpak + Proton-GE ----------
log "Setting up Flathub / Proton-GE"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
runuser -l lied -c 'protonup -y -t GE-Proton --latest || true'

# ---------- services ----------
log "Enabling services"
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

# ---------- perf tuning ----------
log "Applying sysctl/IO/CPU tuning"
cat > /etc/sysctl.d/99-gaming-tweaks.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
kernel.sched_autogroup_enabled = 1
dev.i915.perf_stream_paranoid = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
cat > /etc/default/cpupower <<'EOF'
governor="performance"
EOF
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
cat > /etc/udev/rules.d/60-ioschedulers.rules <<'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
EOF

# ---------- SDDM theme ----------
mkdir -p /etc/sddm.conf.d
THEME=catppuccin-mocha
[[ -d "/usr/share/sddm/themes/Catppuccin-Mocha" ]] && THEME=Catppuccin-Mocha
cat > /etc/sddm.conf.d/theme.conf <<EOF
[Theme]
Current=$THEME
EOF

# ---------- user configs (GTK/env/Discord/Firefox/Qt/Hyprland/Ghostty/Zsh/MangoHud/vkBasalt) ----------
runuser -l lied -c 'mkdir -p $HOME/.config/gtk-3.0 $HOME/.config/gtk-4.0 $HOME/.config/environment.d $HOME/.local/bin $HOME/.local/share/applications'
runuser -l lied -c 'cat > $HOME/.config/gtk-3.0/settings.ini <<'"'"'EOF'"'"'
[Settings]
gtk-theme-name=Catppuccin-Mocha-Standard-Blue-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Catppuccin-Mocha-Dark-Cursors
gtk-application-prefer-dark-theme=1
EOF
'
runuser -l lied -c 'ln -sf $HOME/.config/gtk-3.0/settings.ini $HOME/.config/gtk-4.0/settings.ini'
runuser -l lied -c 'cat > $HOME/.config/environment.d/wayland.conf <<'"'"'EOF'"'"'
MOZ_ENABLE_WAYLAND=1
MOZ_WEBRENDER=1
MOZ_DISABLE_RDD_SANDBOX=1
LIBVA_DRIVER_NAME=nvidia
ELECTRON_OZONE_PLATFORM_HINT=auto
DISCORD_FLAGS=--enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland
EOF
'
runuser -l lied -c 'cat > $HOME/.local/bin/discord-wayland <<'"'"'EOF'"'"'
#!/bin/bash
exec /usr/bin/discord --enable-features=UseOzonePlatform,WebRTCPipeWireCapturer,WaylandWindowDecorations --ozone-platform=wayland "$@"
EOF
'
runuser -l lied -c 'chmod +x $HOME/.local/bin/discord-wayland'
runuser -l lied -c 'cat > $HOME/.local/share/applications/discord.desktop <<'"'"'EOF'"'"'
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
EOF
'
mkdir -p /usr/lib/firefox/distribution
cat > /usr/lib/firefox/distribution/policies.json <<'EOF'
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
EOF
pacman -S --needed --noconfirm qt6ct qt5ct
runuser -l lied -c 'mkdir -p $HOME/.config && echo "[General]\nicon_theme=Papirus-Dark" > $HOME/.config/qt6ct.conf'
runuser -l lied -c 'mkdir -p $HOME/.config && echo "[General]\nicon_theme=Papirus-Dark" > $HOME/.config/qt5ct.conf'
runuser -l lied -c 'mkdir -p $HOME/.config/Kvantum && echo -e "[General]\ntheme=Catppuccin-Mocha" > $HOME/.config/Kvantum/kvantum.kvconfig'
runuser -l lied -c 'mkdir -p $HOME/.config/hypr $HOME/Pictures/Wallpapers'
runuser -l lied -c 'curl -fsSL -o $HOME/Pictures/Wallpapers/anime-dark-1.jpg https://images.unsplash.com/photo-1519681393784-d120267933ba?q=80&w=2560&auto=format&fit=crop'
runuser -l lied -c 'cat > $HOME/.config/hypr/hyprpaper.conf <<'"'"'EOF'"'"'
preload = ~/Pictures/Wallpapers/anime-dark-1.jpg
wallpaper = ,~/Pictures/Wallpapers/anime-dark-1.jpg
EOF
'
runuser -l lied -c 'cat > $HOME/.config/hypr/hyprland.conf <<'"'"'EOF'"'"'
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
input { kb_layout = gb; follow_mouse = 1; sensitivity = 0; accel_profile = flat; touchpad { natural_scroll = true } }
general { gaps_in = 8; gaps_out = 16; border_size = 3; col.active_border = rgba(89b4faee) rgba(74c7ecaa) 45deg; col.inactive_border = rgba(181825aa); layout = master }
decoration { rounding = 12; blur { enabled = true; size = 8; passes = 2; noise = 0.02 } drop_shadow = true; shadow_range = 20; shadow_render_power = 3 }
animations { enabled = true; bezier = smooth, 0.05, 0.9, 0.1, 1.0; animation = windows, 1, 6, smooth, slide; animation = border, 1, 10, smooth; animation = fade, 1, 6, smooth; animation = workspaces, 1, 5, smooth, slide }
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
EOF
'
runuser -l lied -c 'mkdir -p $HOME/.config/ghostty'
runuser -l lied -c 'cat > $HOME/.config/ghostty/config <<'"'"'EOF'"'"'
font-family = JetBrainsMono Nerd Font
font-size = 12
cursor-style = beam
window-padding-x = 10
window-padding-y = 10
theme = Catppuccin-Mocha
shell-integration = zsh
EOF
'
runuser -l lied -c 'cat > $HOME/.zshrc <<'"'"'EOF'"'"'
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
EOF
'
runuser -l lied -c 'mkdir -p $HOME/.config/MangoHud $HOME/.config/vkBasalt'
runuser -l lied -c 'cat > $HOME/.config/MangoHud/MangoHud.conf <<'"'"'EOF'"'"'
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
EOF
'
runuser -l lied -c 'cat > $HOME/.config/vkBasalt/vkBasalt.conf <<'"'"'EOF'"'"'
effects = cas
casSharpness = 0.2
EOF
'

# Default shell
if [[ -x /bin/zsh ]]; then
  chsh -s /bin/zsh lied || warn "Could not set zsh as default shell."
else
  warn "zsh not found; skipping chsh."
fi

# Cleanup sudoers temp
rm -f /etc/sudoers.d/99_wheel_nopasswd || true

# ---------- NVIDIA sanity ----------
ensure_helpers
echo
echo "[NV] Verifying NVIDIA driver…"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  warn "nvidia-smi not found. Driver may not be installed."
elif ! nvidia-smi >/dev/null 2>&1; then
  warn "nvidia-smi failed. Check DKMS build/logs."
else
  log "nvidia-smi OK — driver loaded."
fi
lsmod | grep -q '^nvidia' || warn "nvidia kernel module not loaded."
grep -q 'nvidia_drm.modeset=1' /proc/cmdline 2>/dev/null || warn "kernel cmdline missing nvidia_drm.modeset=1."

# ---------- final summary ----------
ensure_helpers
echo
echo "========================================"
echo "Logs saved to: $LOGFILE"
if [[ "${WARNINGS:-0}" -gt 0 ]]; then
  echo -e "⚠  ${YELLOW}Installation completed with $WARNINGS warning(s).${NC}"
  echo -e "   Review [WARN] lines above before rebooting."
else
  echo -e "✅ ${GREEN}Installation completed successfully with no warnings.${NC}"
fi
echo "========================================"
echo
read -rp "Press Y to reboot now, or any other key to stay in shell: " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  log "Rebooting…"
  reboot
else
  log "Staying in shell. Reboot when ready."
fi
