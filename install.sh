#!/bin/bash
# ============================================================
# Arch Linux ZEN Gaming Auto-Installer — single file (FIXED)
# ============================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Failed at line $LINENO"; exit 1' ERR
log(){ echo -e "\033[0;32m[$(date +'%F %T')]\033[0m $*"; }
die(){ echo -e "\033[0;31m[ERROR]\033[0m $*" 1>&2; exit 1; }

(( EUID == 0 )) || die "Run as root."
[[ -n "${INSTALL_DISK:-}" ]] || die "Set INSTALL_DISK (e.g. /dev/nvme0n1)."
[[ -b "$INSTALL_DISK"      ]] || die "Block device $INSTALL_DISK not found."

# ---------- passwords ----------
read -rs -p "Password for user 'lied': " PW1; echo
read -rs -p "Confirm password: " PW2; echo
[[ -n "$PW1" && "$PW1" == "$PW2" ]] || die "Passwords empty/mismatch."
read -rp "Set a root password too? [y/N] " SETROOT
if [[ "${SETROOT,,}" == "y" ]]; then
  read -rs -p "Root password: " RPW1; echo
  read -rs -p "Confirm root password: " RPW2; echo
  [[ -n "$RPW1" && "$RPW1" == "$RPW2" ]] || die "Root passwords empty/mismatch."
fi

# ---------- partition & format ----------
timedatectl set-ntp true || true
log "Partitioning $INSTALL_DISK (EFI + XFS root)"
wipefs -af "$INSTALL_DISK" || true
sgdisk --zap-all "$INSTALL_DISK" || true
sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:"EFI System" "$INSTALL_DISK"
sgdisk -n 2:0:0     -t 2:8300 -c 2:"Arch Linux" "$INSTALL_DISK"

if [[ "$INSTALL_DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${INSTALL_DISK}p1"; ROOT_PART="${INSTALL_DISK}p2"
else
  EFI_PART="${INSTALL_DISK}1";  ROOT_PART="${INSTALL_DISK}2"
fi

mkfs.fat -F32 "$EFI_PART"
mkfs.xfs  -f   "$ROOT_PART"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# ---------- base system ----------
log "Pacstrap base"
pacstrap -K /mnt base base-devel linux-firmware networkmanager sudo nano git curl wget efibootmgr openssh

genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/\<relatime\>/noatime/g' /mnt/etc/fstab || true

# pass secrets into chroot
printf '%s' "$PW1" > /mnt/root/.pw_lied
[[ "${SETROOT,,}" == "y" ]] && printf '%s' "$RPW1" > /mnt/root/.pw_root

# ---------- chroot: configure everything ----------
log "Entering target system (this will look continuous)…"
arch-chroot /mnt /bin/bash <<'CHROOT'
set -Eeuo pipefail

# ---- enable multilib first, then hard refresh ----
if ! grep -Eq '^\s*\[multilib\]' /etc/pacman.conf; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi
pacman -Syyu --noconfirm

# ---- ensure mkinitcpio exists and has a base config ----
pacman -S --noconfirm mkinitcpio
[[ -f /etc/mkinitcpio.conf ]] || install -Dm644 /usr/share/mkinitcpio/mkinitcpio.conf /etc/mkinitcpio.conf || true

# ---- system basics ----
echo "gaming-rig" > /etc/hostname
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "KEYMAP=uk" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# ---- users ----
id -u lied &>/dev/null || useradd -m -G wheel,audio,video,storage,power,network,optical,scanner,rfkill -s /bin/bash lied
printf 'lied:%s\n' "$(cat /root/.pw_lied)" | chpasswd
rm -f /root/.pw_lied
if [[ -f /root/.pw_root ]]; then
  printf 'root:%s\n' "$(cat /root/.pw_root)" | chpasswd; rm -f /root/.pw_root
else
  passwd -l root || true
fi
echo "lied ALL=(ALL) ALL" >> /etc/sudoers

# ---- Install kernel and headers FIRST (prevent fallback generation) ----
# First, ensure the preset exists to prevent fallback
mkdir -p /etc/mkinitcpio.d
cat > /etc/mkinitcpio.d/linux-zen.preset <<'PRESET'
# mkinitcpio preset file for the 'linux-zen' package
# NO FALLBACK IMAGE

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-zen"
ALL_microcode=(/boot/*-ucode.img)

PRESETS=('default')

default_image="/boot/initramfs-linux-zen.img"
default_options=""

# Explicitly NO fallback preset
PRESET

# Now install kernel (it won't create fallback because preset already exists)
pacman -S --noconfirm linux-zen linux-zen-headers

# ---- NVIDIA KMS + mkinitcpio via drop-in (AFTER kernel install) ----
mkdir -p /etc/mkinitcpio.conf.d
cat > /etc/mkinitcpio.conf.d/90-nvidia.conf <<'EOF'
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)
EOF

echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'BL'
blacklist nouveau
options nouveau modeset=0
BL

# ---- Ensure preset still has NO fallback (in case kernel install modified it) ----
cat > /etc/mkinitcpio.d/linux-zen.preset <<'PRESET'
# mkinitcpio preset file for the 'linux-zen' package
# NO FALLBACK IMAGE

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-zen"
ALL_microcode=(/boot/*-ucode.img)

PRESETS=('default')

default_image="/boot/initramfs-linux-zen.img"
default_options=""

# Explicitly NO fallback preset
PRESET

# ---- official repo packages (NVIDIA after kernel) ----
pacman -S --noconfirm \
  intel-ucode \
  nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils \
  wayland wayland-protocols xdg-utils xdg-user-dirs \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  xorg-xwayland hyprland hyprpaper hyprcursor \
  wl-clipboard grim slurp swappy wf-recorder cliphist \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
  networkmanager network-manager-applet bluez bluez-utils blueman \
  polkit-gnome sddm firefox discord \
  thunar thunar-archive-plugin thunar-volman tumbler ffmpegthumbnailer \
  ffmpeg libheif gvfs gvfs-mtp gvfs-smb gvfs-nfs udisks2 polkit \
  nano curl wget unzip unrar p7zip rsync htop btop fastfetch fzf ripgrep fd bat eza tree jq yq git-delta \
  zsh zsh-autosuggestions zsh-syntax-highlighting starship zellij tmux zoxide \
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-roboto \
  papirus-icon-theme gtk3 gtk4 qt6-base qt6-wayland qt5-base qt5-wayland kvantum qt6ct qt5ct \
  gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav gst-vaapi \
  vulkan-icd-loader vulkan-tools lib32-vulkan-icd-loader \
  steam wine wine-gecko wine-mono lutris gamemode lib32-gamemode \
  mangohud lib32-mangohud gamescope goverlay nvtop \
  flatpak ntfs-3g nvme-cli xfsprogs btrfs-progs dosfstools \
  cpupower lm_sensors thermald irqbalance zram-generator avahi nss-mdns \
  mako kanshi hypridle openssh iperf3 yt-dlp aria2 samba smbclient

# remove wofi if installed
pacman -Q wofi &>/dev/null && pacman -Rns --noconfirm wofi || true

# ---- Regenerate initramfs with NVIDIA modules (NO FALLBACK) ----
# Clean up any fallback images that might have been created
rm -f /boot/initramfs-linux-zen-fallback.img
# Regenerate with our preset that has no fallback
mkinitcpio -P

# ---- systemd-boot + fallback BOOTX64.EFI + set BootOrder ----
bootctl install --esp-path=/boot || true
ROOT_UUID=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE /)")
ROOT_FS=$(findmnt -no FSTYPE /)
cat > /boot/loader/loader.conf <<'L'
timeout 0
default arch-linux-zen
editor no
L
cat > /boot/loader/entries/arch-linux-zen.conf <<EOF
title Arch Linux Zen (Gaming)
linux /vmlinuz-linux-zen
initrd /intel-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=${ROOT_UUID} rw rootfstype=${ROOT_FS} nvidia_drm.modeset=1 nvidia_drm.fbdev=1
EOF
mkdir -p /boot/EFI/Boot
cp -f /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/Boot/BOOTX64.EFI || true
bootctl --esp-path=/boot list || true
BOOT_SRC=$(findmnt -no SOURCE /boot)
BOOT_DISK="/dev/$(lsblk -no PKNAME "$BOOT_SRC")"
BOOT_PART=$(lsblk -no PARTNUM "$BOOT_SRC")
LABEL="Arch (systemd-boot)"
LOADER='\EFI\systemd\systemd-bootx64.efi'
efibootmgr -v | grep -qi "$LABEL" || efibootmgr --create --disk "$BOOT_DISK" --part "$BOOT_PART" --label "$LABEL" --loader "$LOADER" || true
NEW_ID=$(efibootmgr -v | awk -v L="$LABEL" '/Boot[0-9A-Fa-f]+\*/{id=$1; sub(/^Boot/,"",id); sub(/\*/,"",id); if (index($0,L)) print id}' | head -n1)
if [[ -n "$NEW_ID" ]]; then
  CUR=$(efibootmgr | awk -F': ' '/BootOrder/ {print $2}')
  ORDER="$NEW_ID"
  IFS=',' read -r -a A <<< "$CUR"; for id in "${A[@]}"; do [[ "$id" != "$NEW_ID" ]] && ORDER="$ORDER,$id"; done
  efibootmgr -o "$ORDER" || true
fi
bootctl update || true

# ---- yay (AUR) + AUR packages ----
pacman -S --needed --noconfirm git base-devel
sudo -u lied bash -c 'mkdir -p $HOME/.cache/yay && cd $HOME/.cache/yay && rm -rf yay-bin && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm'
sudo -u lied yay -S --needed --noconfirm \
  rofi-wayland hyprpicker raw-thumbnailer thunar-vcs-plugin \
  ghostty-bin openasar-bin equicord \
  protontricks vkbasalt lib32-vkbasalt \
  catppuccin-ghostty-git catppuccin-gtk-theme-mocha catppuccin-kvantum-theme-git catppuccin-cursors catppuccin-sddm-theme-git

# Apply OpenAsar + Equicord
sudo -u lied bash -lc 'command -v openasar >/dev/null 2>&1 && openasar -i || true'
sudo -u lied bash -lc 'command -v equicord  >/dev/null 2>&1 && equicord inject stable || true'

# ---- Flatpak + Proton-GE ----
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
sudo -u lied protonup -y -t GE-Proton --latest || true

# ---- services ----
systemctl enable NetworkManager.service bluetooth.service sddm.service thermald.service || true
systemctl enable irqbalance.service fstrim.timer avahi-daemon.service || true
systemctl enable cpupower.service nvidia-persistenced.service nvidia-powerd.service || true
systemctl enable sshd.service smb.service nmb.service
systemctl set-default graphical.target

# ---- perf tuning ----
cat > /etc/sysctl.d/99-gaming-tweaks.conf <<'E'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
kernel.sched_autogroup_enabled = 1
dev.i915.perf_stream_paranoid = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
E
cat > /etc/default/cpupower <<'E'
governor="performance"
E
cat > /etc/systemd/zram-generator.conf <<'E'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
E
cat > /etc/udev/rules.d/60-ioschedulers.rules <<'E'
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]",   ATTR{queue/scheduler}="mq-deadline"
E

# ---- SDDM theme ----
mkdir -p /etc/sddm.conf.d
THEME="elarun"
[[ -d "/usr/share/sddm/themes/catppuccin-mocha" ]] && THEME="catppuccin-mocha"
[[ -d "/usr/share/sddm/themes/Catppuccin-Mocha" ]] && THEME="Catppuccin-Mocha"
cat > /etc/sddm.conf.d/theme.conf <<EOF
[Theme]
Current=$THEME
EOF

# ---- user configs: Rofi theme, Mako, Hyprland, Ghostty, Zsh, Discord wrapper ----
sudo -u lied mkdir -p /home/lied/.config/{rofi,mako,hypr,ghostty} /home/lied/.local/{bin,share/applications} /home/lied/Pictures/Wallpapers
curl -fsSL -o /home/lied/Pictures/Wallpapers/anime-dark-1.jpg https://images.unsplash.com/photo-1519681393784-d120267933ba?q=80&w=2560&auto=format&fit=crop || true

cat > /home/lied/.config/rofi/catppuccin-mocha.rasi <<'R'
* { bg:#1e1e2eFF; fg:#cdd6f4FF; acc:#89b4faFF; sel:#313244FF; bdr:#89b4faFF; font:"JetBrainsMono Nerd Font 12"; }
window { transparency:"real"; background:@bg; border:2; border-color:@bdr; width:720; }
mainbox { padding:12; } inputbar { text-color:@fg; } prompt { text-color:@acc; }
listview { spacing:6; } element { padding:6 10; } element-text { text-color:@fg; highlight:@acc; }
element selected { background:@sel; border:0 0 0 2px; border-color:@acc; }
R

cat > /home/lied/.config/mako/config <<'M'
font=JetBrainsMono Nerd Font 12
background-color=#1e1e2e
text-color=#cdd6f4
border-color=#89b4fa
progress-color=#89b4fa
border-size=2
border-radius=12
padding=10
default-timeout=5000
icon-path=/usr/share/icons/Papirus-Dark
M

cat > /home/lied/.config/hypr/hyprpaper.conf <<'HPP'
preload = ~/Pictures/Wallpapers/anime-dark-1.jpg
wallpaper = ,~/Pictures/Wallpapers/anime-dark-1.jpg
HPP

cat > /home/lied/.config/hypr/hyprland.conf <<'H'
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
exec-once = mako
exec-once = kanshi
exec-once = fastfetch
bind = SUPER, Return, exec, ghostty
bind = SUPER, C, killactive,
bind = SUPER, M, exit,
bind = SUPER, E, exec, thunar
bind = SUPER, Q, exec, rofi -show drun -theme ~/.config/rofi/catppuccin-mocha.rasi
bind = SUPER, W, exec, firefox --private-window
bind = SUPER, S, togglefloating,
bind = SUPER, F, fullscreen,
bind = SUPER, V, exec, cliphist list | rofi -dmenu -theme ~/.config/rofi/catppuccin-mocha.rasi | wl-copy
bind = SUPER, P, exec, hyprpicker -a
H

cat > /home/lied/.config/ghostty/config <<'G'
font-family = JetBrainsMono Nerd Font
font-size = 12
cursor-style = beam
window-padding-x = 10
window-padding-y = 10
theme = Catppuccin-Mocha
shell-integration = zsh
G

cat > /home/lied/.local/bin/discord-wayland <<'D'
#!/bin/bash
exec /usr/bin/discord --enable-features=UseOzonePlatform,WebRTCPipeWireCapturer,WaylandWindowDecorations --ozone-platform=wayland "$@"
D
chmod +x /home/lied/.local/bin/discord-wayland

cat > /home/lied/.local/share/applications/discord.desktop <<'DD'
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
DD

# zsh defaults with performance optimizations
cat > /home/lied/.zshrc <<'Z'
export ZDOTDIR="$HOME"
export EDITOR=nano
export BROWSER=firefox

# Enable Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# History optimizations for 64GB RAM
HISTSIZE=1000000
SAVEHIST=1000000
HISTFILE=$HOME/.zsh_history
setopt EXTENDED_HISTORY
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_FIND_NO_DUPS
setopt HIST_SAVE_NO_DUPS
setopt SHARE_HISTORY

# Performance optimizations
autoload -Uz compinit
if [[ -n ${ZDOTDIR}/.zcompdump(#qN.mh+24) ]]; then
  compinit
else
  compinit -C
fi

# Better completion
setopt AUTO_MENU
setopt AUTO_LIST
setopt COMPLETE_IN_WORD
setopt ALWAYS_TO_END
setopt MENU_COMPLETE

# Load plugins
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
[ -f /usr/share/fzf/completion.zsh ] && source /usr/share/fzf/completion.zsh

# Initialize tools
eval "$(starship init zsh)"
eval "$(zoxide init zsh)"

# Aliases for better defaults
alias ls='eza --icons --group-directories-first'
alias ll='eza -lh --icons --group-directories-first'
alias la='eza -lah --icons --group-directories-first'
alias tree='eza --tree --icons'
alias cat='bat'
alias grep='rg'
alias find='fd'
alias ps='procs'
alias top='btop'
alias vim='nano'

# Gaming aliases
alias gamemode='gamemoderun'
alias fps='mangohud'
alias wine32='WINEARCH=win32 WINEPREFIX=~/.wine32 wine'
alias wine64='WINEARCH=win64 WINEPREFIX=~/.wine64 wine'

# System maintenance
alias update='yay -Syu'
alias cleanup='yay -Sc && sudo journalctl --vacuum-time=7d'
alias nvidia-smi='watch -n 1 nvidia-smi'

# Performance monitoring
alias cpu-watch='watch -n 1 "grep \"^[c]pu MHz\" /proc/cpuinfo"'
alias temp-watch='watch -n 1 sensors'

# Development
export MAKEFLAGS="-j32"
export CARGO_BUILD_JOBS=32
export NODE_OPTIONS="--max-old-space-size=16384"
Z

# Ghostty config
cat > /home/lied/.config/ghostty/config <<'G'
font-family = JetBrainsMono Nerd Font
font-size = 12
cursor-style = beam
cursor-blink = true
window-padding-x = 10
window-padding-y = 10
theme = Catppuccin-Mocha
shell-integration = zsh
copy-on-select = true
gtk-single-instance = true
background-opacity = 0.95
G

# Discord Wayland wrapper
cat > /home/lied/.local/bin/discord-wayland <<'D'
#!/bin/bash
exec /usr/bin/discord \
  --enable-features=UseOzonePlatform,WebRTCPipeWireCapturer,WaylandWindowDecorations,VaapiVideoDecoder \
  --ozone-platform=wayland \
  --enable-gpu-rasterization \
  --enable-zero-copy \
  --ignore-gpu-blocklist \
  --enable-hardware-overlays \
  "$@"
D
chmod +x /home/lied/.local/bin/discord-wayland

cat > /home/lied/.local/share/applications/discord.desktop <<'DD'
[Desktop Entry]
Name=Discord
Comment=Discord (Wayland Optimized)
Exec=/home/lied/.local/bin/discord-wayland
Terminal=false
Type=Application
Icon=discord
Categories=Network;InstantMessaging;
StartupWMClass=discord
X-GNOME-UsesNotifications=true
DD

# Gaming launcher script
cat > /home/lied/.local/bin/game-launch <<'GL'
#!/bin/bash
# Optimized game launcher for 13900KS + 4090
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
export __GL_THREADED_OPTIMIZATIONS=1
export __GL_MaxFramesAllowed=1
export __GL_SYNC_TO_VBLANK=0
export WINE_CPU_TOPOLOGY=8:16
export WINE_LARGE_ADDRESS_AWARE=1
export STAGING_SHARED_MEMORY=1
export STAGING_WRITECOPY=1
export RADV_PERFTEST=nggc,sam,ngg_streamout
export mesa_glthread=true
export DXVK_HUD=compiler
export MANGOHUD=1
export MANGOHUD_CONFIG=cpu_temp,gpu_temp,cpu_power,gpu_power,ram,vram,frametime,fps_limit=0

# Set CPU to performance mode
sudo cpupower frequency-set -g performance

# Launch with gamemode
exec gamemoderun "$@"
GL
chmod +x /home/lied/.local/bin/game-launch

# MangoHud config
mkdir -p /home/lied/.config/MangoHud
cat > /home/lied/.config/MangoHud/MangoHud.conf <<'MH'
# 4090 + 13900KS optimized
toggle_hud=F12
toggle_fps_limit=Shift_L+F1

# Display
fps
fps_limit=0
frametime
frame_timing=1
cpu_stats
cpu_temp
cpu_power
cpu_mhz
gpu_stats
gpu_temp
gpu_power
gpu_core_clock
gpu_mem_clock
vram
ram
vulkan_driver
gamemode
wine

# Position
position=top-left
offset_x=10
offset_y=10
width=320
font_size=20

# Colors (Catppuccin theme)
background_alpha=0.4
background_color=1E1E2E
text_color=CDD6F4
gpu_color=89B4FA
cpu_color=F38BA8
vram_color=A6E3A1
ram_color=F9E2AF
MH

# Fix ownership of user configs
chown -R lied:lied /home/lied

# Samba usershares + mDNS
groupadd -f sambashare
usermod -aG sambashare lied
install -d -m 1770 -o root -g sambashare /var/lib/samba/usershares
grep -q "usershare path = /var/lib/samba/usershares" /etc/samba/smb.conf 2>/dev/null || cat >> /etc/samba/smb.conf <<'SMB'
[global]
   usershare path = /var/lib/samba/usershares
   usershare max shares = 100
   usershare allow guests = yes
SMB
sed -i 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] resolve dns myhostname/' /etc/nsswitch.conf || true

# default shell
chsh -s /bin/zsh lied || true

CHROOT

# ---------- wrap up ----------
echo
echo "========================================"
echo "Install complete!"
echo "========================================"
read -rp "Reboot now? [Y/n] " ANS
sync
umount -R /mnt || umount -R -l /mnt
[[ "${ANS,,}" != "n" ]] && reboot -f || log "Reboot skipped. You can reboot manually."
