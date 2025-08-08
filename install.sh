#!/bin/bash
# ============================================================
# Arch Linux ZEN Gaming Auto-Installer — single-file, unattended
# ============================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Failed at line $LINENO"; exit 1' ERR

# -------- helpers --------
log(){ echo -e "\033[0;32m[$(date +'%F %T')]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; : $((WARNINGS++)); }
die(){  echo -e "\033[0;31m[ERROR]\033[0m $*" 1>&2; exit 1; }
: "${WARNINGS:=0}"

(( EUID == 0 )) || die "Run as root."
IN_ISO=$([ -d /run/archiso ] && echo 1 || echo 0)

# logging
if [[ "$IN_ISO" == 1 ]]; then LOGFILE="/root/arch-install.log"; else LOGFILE="/var/log/installer.log"; mkdir -p /var/log || true; fi
exec > >(tee -a "$LOGFILE") 2>&1

# ============================================================
# Live ISO flow: partition + base + chroot + auto reboot
# ============================================================
if [[ "$IN_ISO" == 1 ]]; then
  log "[1/7] Preparing disk"
  [[ -n "${INSTALL_DISK:-}" ]] || die "Set INSTALL_DISK (e.g. /dev/nvme0n1)."
  [[ -b "$INSTALL_DISK"      ]] || die "Block device $INSTALL_DISK not found."
  timedatectl set-ntp true || true

  wipefs -af "$INSTALL_DISK" || true
  sgdisk --zap-all "$INSTALL_DISK" || true
  sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:"EFI System" "$INSTALL_DISK"
  sgdisk -n 2:0:0     -t 2:8300 -c 2:"Arch Linux" "$INSTALL_DISK"

  if [[ "$INSTALL_DISK" =~ nvme|mmcblk ]]; then EFI_PART="${INSTALL_DISK}p1"; ROOT_PART="${INSTALL_DISK}p2"; else EFI_PART="${INSTALL_DISK}1"; ROOT_PART="${INSTALL_DISK}2"; fi

  log "[2/7] Formatting & mounting"
  mkfs.fat -F32 "$EFI_PART"
  mkfs.xfs -f "$ROOT_PART"
  mount "$ROOT_PART" /mnt
  mkdir -p /mnt/boot
  mount "$EFI_PART" /mnt/boot

  log "[3/7] Installing base system"
  # NOTE: kernel installed later (after we force no-fallback mkinitcpio)
  pacstrap -K /mnt base base-devel linux-firmware networkmanager sudo nano git curl wget efibootmgr openssh

  log "[4/7] Fstab"
  genfstab -U /mnt >> /mnt/etc/fstab
  sed -i 's/\<relatime\>/noatime/g' /mnt/etc/fstab || true

  log "[5/7] Handing off into system (this looks continuous)"
  mkdir -p /mnt/var/log /mnt/etc
  cp -f "$LOGFILE" /mnt/var/log/installer.log || true
  install -Dm755 "$0" /mnt/root/install.sh
  cp -L /etc/resolv.conf /mnt/etc/resolv.conf || true

  arch-chroot /mnt /bin/bash /root/install.sh

  log "[6/7] Finalizing"
  if [[ -f /mnt/root/.install_done ]]; then
    sync
    umount -R /mnt || umount -R -l /mnt
    log "[7/7] Rebooting…"
    reboot -f
  else
    die "Install did not complete (flag missing)."
  fi
fi

# ============================================================
# Inside target system (chroot) — configure everything
# ============================================================

log "[A] System config"
echo "gaming-rig" > /etc/hostname
printf "en_GB.UTF-8 UTF-8\n" > /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "KEYMAP=uk" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# user: unattended (password 'arch', force change), lock root for safety
id -u lied &>/dev/null || useradd -m -G wheel,audio,video,storage,power,network,optical,scanner,rfkill -s /bin/bash lied
echo "lied:arch" | chpasswd
chage -d 0 lied
passwd -l root || true
echo "lied ALL=(ALL) ALL" >> /etc/sudoers

log "[B] Packages (official repos)"
pacman -Syu --noconfirm
pacman -S --noconfirm \
  intel-ucode wayland wayland-protocols xdg-utils xdg-user-dirs \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  xorg-xwayland hyprland hyprpaper hyprcursor \
  wl-clipboard grim slurp swappy wf-recorder \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
  networkmanager network-manager-applet bluez bluez-utils blueman \
  polkit-gnome sddm firefox discord thunar thunar-archive-plugin file-roller \
  thunar-media-tags-plugin thunar-shares-plugin thunar-volman tumbler ffmpegthumbnailer \
  ffmpeg mediainfo libheif heif-pixbuf gvfs gvfs-mtp gvfs-smb gvfs-nfs udisks2 polkit \
  curl wget unzip unrar p7zip rsync nano \
  htop btop fastfetch fzf ripgrep fd bat eza tree zsh starship zellij tmux zoxide git-delta jq yq \
  papirus-icon-theme gtk3 gtk4 qt6-base qt6-wayland qt5-base qt5-wayland kvantum \
  gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav \
  gst-vaapi libva libva-utils vulkan-icd-loader vulkan-tools lib32-vulkan-icd-loader \
  flatpak ntfs-3g nvme-cli xfsprogs btrfs-progs dosfstools \
  cpupower lm_sensors thermald irqbalance zram-generator avahi nfs-utils \
  mako kanshi easyeffects openssh steam-devices iperf3 yt-dlp aria2 samba smbclient nss-mdns

# keep only the Hyprland portal
pacman -Q xdg-desktop-portal-gtk &>/dev/null && pacman -Rns --noconfirm xdg-desktop-portal-gtk || true
# remove wofi (we're switching to rofi-wayland)
pacman -Q wofi &>/dev/null && pacman -Rns --noconfirm wofi || true

runuser -l lied -c 'xdg-user-dirs-update'

log "[C] Initramfs preset FIRST (no fallback) + NVIDIA KMS"
# mkinitcpio config upfront so hooks use it from the start
sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf || true
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf || true
echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'BL_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
BL_NOUVEAU

mkdir -p /etc/mkinitcpio.d
cat > /etc/mkinitcpio.d/linux-zen.preset <<'EOF'
ALL_config="/etc/mkinitcpio.conf"
PRESETS=('default')
default_image="/boot/initramfs-linux-zen.img"
# no fallback preset on purpose
EOF

log "[D] Kernel + NVIDIA"
pacman -S --noconfirm linux-zen linux-zen-headers nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings vulkan-nvidia lib32-vulkan-nvidia
mkinitcpio -P
rm -f /boot/initramfs-linux-zen-fallback.img || true

log "[E] systemd-boot entry + set this ESP first"
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

for f in /boot/vmlinuz-linux-zen /boot/initramfs-linux-zen.img /boot/intel-ucode.img; do
  [[ -f "$f" ]] || die "Missing $f — kernel/initramfs/microcode not in place."
done

BOOT_SRC="$(findmnt -no SOURCE /boot)"
BOOT_DISK="/dev/$(lsblk -no PKNAME "$BOOT_SRC")"
BOOT_PART="$(lsblk -no PARTNUM "$BOOT_SRC")"
LABEL="Arch (systemd-boot)"
LOADER='\EFI\systemd\systemd-bootx64.efi'
efibootmgr -v | grep -qi "$LABEL" || efibootmgr --create --disk "$BOOT_DISK" --part "$BOOT_PART" --label "$LABEL" --loader "$LOADER" || warn "efibootmgr create failed"
NEW_ID="$(efibootmgr -v | awk -v L="$LABEL" '/Boot[0-9A-Fa-f]+\*/{id=$1; sub(/^Boot/,"",id); sub(/\*/,"",id); if (index($0,L)) print id}' | head -n1)"
if [[ -n "$NEW_ID" ]]; then
  CUR_ORDER="$(efibootmgr | awk -F': ' '/BootOrder/ {print $2}')"
  ORDER="$NEW_ID"; IFS=',' read -r -a IDS <<< "$CUR_ORDER"; for id in "${IDS[@]}"; do [[ "$id" != "$NEW_ID" ]] && ORDER="$ORDER,$id"; done
  efibootmgr -o "$ORDER" || true
fi
bootctl update || true

log "[F] yay + AUR apps (OpenAsar, Equicord, Rofi, etc.)"
pacman -S --needed --noconfirm git base-devel
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99_wheel_nopasswd; chmod 440 /etc/sudoers.d/99_wheel_nopasswd
runuser -l lied -c 'mkdir -p $HOME/.cache/yay && cd $HOME/.cache/yay && rm -rf yay-bin && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm'
runuser -l lied -c 'yay -S --needed --noconfirm \
  nvidia-vaapi-driver dxvk-bin dxvk-nvapi heroic-games-launcher-bin ghostty-bin openasar-bin equicord protonup-ng \
  catppuccin-ghostty-git catppuccin-gtk-theme-mocha catppuccin-kvantum-theme-git catppuccin-cursors catppuccin-sddm-theme-git \
  rofi-wayland hyprpicker thunar-vcs-plugin raw-thumbnailer antimicrox atuin-bin thefuck'
# OpenAsar + Equicord apply
runuser -l lied -c 'command -v openasar >/dev/null 2>&1 && openasar -i || true'
runuser -l lied -c 'command -v equicord >/dev/null 2>&1 && equicord inject stable || true'
# Proton-GE
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
runuser -l lied -c 'protonup -y -t GE-Proton --latest || true'

log "[G] Services"
systemctl enable NetworkManager.service bluetooth.service sddm.service thermald.service || true
systemctl enable irqbalance.service || true
systemctl enable fstrim.timer avahi-daemon.service || true
systemctl enable cpupower.service nvidia-persistenced.service nvidia-powerd.service || true
systemctl enable sshd.service
systemctl enable smb.service nmb.service
systemctl set-default graphical.target

log "[H] Performance tuning"
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

log "[I] SDDM theme"
mkdir -p /etc/sddm.conf.d
THEME="elarun"
[[ -d "/usr/share/sddm/themes/catppuccin-mocha" ]] && THEME="catppuccin-mocha"
[[ -d "/usr/share/sddm/themes/Catppuccin-Mocha" ]] && THEME="Catppuccin-Mocha"
cat > /etc/sddm.conf.d/theme.conf <<EOF
[Theme]
Current=$THEME
EOF

log "[J] User configs (Rofi theme, Mako, Hyprland, Ghostty, Zsh, Thunar shares)"
# Rofi + Mako themes
runuser -l lied -c 'mkdir -p $HOME/.config/rofi $HOME/.config/mako'
runuser -l lied -c 'cat > $HOME/.config/rofi/catppuccin-mocha.rasi << "RASI"
* { bg: #1e1e2eFF; fg: #cdd6f4FF; acc: #89b4faFF; sel: #313244FF; bdr: #89b4faFF; font: "JetBrainsMono Nerd Font 12"; }
window { transparency:"real"; background:@bg; border:2; border-color:@bdr; width:720; }
mainbox { padding:12; } inputbar { text-color:@fg; } prompt { text-color:@acc; }
listview { spacing:6; } element { padding:6 10; } element-text { text-color:@fg; highlight:@acc; }
element selected { background:@sel; border:0 0 0 2px; border-color:@acc; }
RASI'
runuser -l lied -c 'cat > $HOME/.config/mako/config << "MAKO"
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
MAKO'

# Hyprland config (Rofi, Mako, Kanshi, cliphist via Rofi)
runuser -l lied -c 'mkdir -p $HOME/.config/hypr $HOME/Pictures/Wallpapers'
runuser -l lied -c 'curl -fsSL -o $HOME/Pictures/Wallpapers/anime-dark-1.jpg https://images.unsplash.com/photo-1519681393784-d120267933ba?q=80&w=2560&auto=format&fit=crop'
runuser -l lied -c 'cat > $HOME/.config/hypr/hyprpaper.conf <<EOF
preload = ~/Pictures/Wallpapers/anime-dark-1.jpg
wallpaper = ,~/Pictures/Wallpapers/anime-dark-1.jpg
EOF'
runuser -l lied -c 'cat > $HOME/.config/hypr/hyprland.conf << "EOF"
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
EOF'

# Ghostty
runuser -l lied -c 'mkdir -p $HOME/.config/ghostty'
runuser -l lied -c 'cat > $HOME/.config/ghostty/config << "EOF"
font-family = JetBrainsMono Nerd Font
font-size = 12
cursor-style = beam
window-padding-x = 10
window-padding-y = 10
theme = Catppuccin-Mocha
shell-integration = zsh
EOF'

# Zsh defaults (EDITOR=nano) + QoL
runuser -l lied -c 'cat > $HOME/.zshrc << "EOF"
export ZDOTDIR="$HOME"
export EDITOR=nano
autoload -Uz compinit && compinit
setopt AUTO_MENU AUTO_LIST COMPLETE_IN_WORD
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE EXTENDED_HISTORY
HISTSIZE=100000; SAVEHIST=100000; HISTFILE=$HOME/.zsh_history
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
[ -f /usr/share/fzf/completion.zsh ] && source /usr/share/fzf/completion.zsh
eval "$(starship init zsh)"
eval "$(zoxide init zsh)"
eval "$(atuin init zsh 2>/dev/null)" || true
eval "$(thefuck --alias 2>/dev/null)" || true
alias ls="eza --icons=auto --group-directories-first"
alias ll="ls -alh"
alias cat="bat --paging=never"
alias grep="rg"
EOF'

# Qt/Kvantum basic
pacman -S --needed --noconfirm qt6ct qt5ct
runuser -l lied -c 'mkdir -p $HOME/.config/Kvantum && echo -e "[General]\ntheme=Catppuccin-Mocha" > $HOME/.config/Kvantum/kvantum.kvconfig'
runuser -l lied -c 'echo -e "[General]\nicon_theme=Papirus-Dark" > $HOME/.config/qt6ct.conf'
runuser -l lied -c 'echo -e "[General]\nicon_theme=Papirus-Dark" > $HOME/.config/qt5ct.conf'

# GTK theme defaults
runuser -l lied -c 'mkdir -p $HOME/.config/gtk-3.0 $HOME/.config/gtk-4.0'
runuser -l lied -c 'cat > $HOME/.config/gtk-3.0/settings.ini << "EOF"
[Settings]
gtk-theme-name=Catppuccin-Mocha-Standard-Blue-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Catppuccin-Mocha-Dark-Cursors
gtk-application-prefer-dark-theme=1
EOF'
runuser -l lied -c 'ln -sf $HOME/.config/gtk-3.0/settings.ini $HOME/.config/gtk-4.0/settings.ini'

# Discord wrapper
runuser -l lied -c 'mkdir -p $HOME/.local/bin $HOME/.local/share/applications'
runuser -l lied -c 'cat > $HOME/.local/bin/discord-wayland << "EOF"
#!/bin/bash
exec /usr/bin/discord --enable-features=UseOzonePlatform,WebRTCPipeWireCapturer,WaylandWindowDecorations --ozone-platform=wayland "$@"
EOF
chmod +x $HOME/.local/bin/discord-wayland'
runuser -l lied -c 'cat > $HOME/.local/share/applications/discord.desktop << "EOF"
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
EOF'

# Firefox policy
mkdir -p /usr/lib/firefox/distribution
cat > /usr/lib/firefox/distribution/policies.json << 'EOF'
{ "policies": { "Preferences": {
  "media.ffmpeg.vaapi.enabled": true, "media.rdd-ffmpeg.enabled": true,
  "media.hardware-video-decoding.enabled": true, "media.hardware-video-decoding.force-enabled": true,
  "widget.dmabuf.force-enabled": true, "gfx.webrender.all": true, "layers.acceleration.force-enabled": true,
  "gfx.x11-egl.force-enabled": true, "gfx.webrender.precache-shaders": true,
  "widget.use-xdg-desktop-portal.file-picker": 1, "widget.use-xdg-desktop-portal": 1 } } }
EOF

# Samba usershares (+ mDNS)
groupadd -f sambashare
usermod -aG sambashare lied
install -d -m 1770 -o root -g sambashare /var/lib/samba/usershares
if ! grep -q "usershare path = /var/lib/samba/usershares" /etc/samba/smb.conf 2>/dev/null; then
  mkdir -p /etc/samba
  cat >> /etc/samba/smb.conf <<'SMB'
[global]
   usershare path = /var/lib/samba/usershares
   usershare max shares = 100
   usershare allow guests = yes
SMB
fi
# mDNS in nsswitch
sed -i 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] resolve dns myhostname/' /etc/nsswitch.conf || true

# Default shell + cleanup
command -v zsh >/dev/null && chsh -s /bin/zsh lied || warn "Could not set zsh as default shell."
rm -f /etc/sudoers.d/99_wheel_nopasswd || true

# Done — signal ISO side to unmount & reboot
echo
echo "========================================"
echo "Logs: $LOGFILE"
[[ "${WARNINGS:-0}" -gt 0 ]] && echo -e "⚠  \033[1;33mCompleted with $WARNINGS warning(s).\033[0m" || echo -e "✅ \033[0;32mCompleted successfully with no warnings.\033[0m"
echo "========================================"
touch /root/.install_done
exit 0
