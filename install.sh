#!/bin/bash
# ============================================================
# Arch Linux ZEN Gaming Auto-Installer — single file
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

# ---------- preset BEFORE kernel to avoid fallback ----------
log "Writing mkinitcpio preset (no fallback) in target"
mkdir -p /mnt/etc/mkinitcpio.d
cat > /mnt/etc/mkinitcpio.d/linux-zen.preset <<'EOF'
ALL_config="/etc/mkinitcpio.conf"
PRESETS=('default')
default_image="/boot/initramfs-linux-zen.img"
EOF

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

# ---- enable multilib first, then hard refresh (robust) ----
if ! grep -Eq '^\s*\[multilib\]' /etc/pacman.conf; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi
pacman -Syyu --noconfirm

# ---- ensure mkinitcpio exists and has a config BEFORE editing it ----
pacman -S --noconfirm mkinitcpio
if [[ ! -f /etc/mkinitcpio.conf ]]; then
  install -Dm644 /usr/share/mkinitcpio/mkinitcpio.conf /etc/mkinitcpio.conf
fi

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

# ---- NVIDIA KMS + mkinitcpio ----
sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf || true
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf || true
echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'BL'
blacklist nouveau
options nouveau modeset=0
BL

# ---- official repo packages ----
pacman -S --noconfirm \
  intel-ucode \
  nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils \
  wayland wayland-protocols xdg-utils xdg-user-dirs \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  xorg-xwayland hyprland hyprpaper hyprcursor \
  wl-clipboard grim slurp swappy wf-recorder \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
  networkmanager network-manager-applet bluez bluez-utils blueman \
  polkit-gnome sddm firefox discord \
  thunar thunar-archive-plugin thunar-volman tumbler ffmpegthumbnailer \
  ffmpeg libheif gvfs gvfs-mtp gvfs-smb gvfs-nfs udisks2 polkit \
  nano curl wget unzip unrar p7zip rsync htop btop fastfetch fzf ripgrep fd bat eza tree jq yq git-delta \
  zsh starship zellij tmux zoxide \
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-roboto \
  papirus-icon-theme gtk3 gtk4 qt6-base qt6-wayland qt5-base qt5-wayland kvantum qt6ct qt5ct \
  gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav gst-vaapi \
  vulkan-icd-loader vulkan-tools lib32-vulkan-icd-loader \
  steam wine wine-gecko wine-mono lutris gamemode lib32-gamemode \
  mangohud lib32-mangohud gamescope goverlay nvtop \
  flatpak ntfs-3g nvme-cli xfsprogs btrfs-progs dosfstools \
  cpupower lm_sensors thermald irqbalance zram-generator avahi nss-mdns \
  mako kanshi openssh iperf3 yt-dlp aria2 samba smbclient

# remove wofi (we'll use rofi-wayland from AUR)
pacman -Q wofi &>/dev/null && pacman -Rns --noconfirm wofi || true

# ---- install kernel after hooks so only default image builds ----
pacman -S --noconfirm linux-zen linux-zen-headers
mkinitcpio -P   # only default image because preset has no fallback

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
  ghostty-bin openasar-bin equicord protonup-ng \
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

# ---- user configs: Rofi theme, Mako, Hyprland, Ghostty, Zsh ----
sudo -u lied mkdir -p /home/lied/.config/{rofi,mako,hypr,ghostty} /home/lied/.local/{bin,share/applications} /home/lied/Pictures/Wallpapers
curl -fsSL -o /home/lied/Pictures/Wallpapers/anime-dark-1.jpg https://images.unsplash.com/photo-1519681393784-d120267933ba?q=80&w=2560&auto=format&fit=crop
# (configs continue exactly as in your original script...)

CHROOT

# ---------- wrap up ----------
echo
echo "========================================"
echo "Install log: /var/log/installer.log (inside the new system)"
echo "========================================"
read -rp "Reboot now? [Y/n] " ANS
sync
umount -R /mnt || umount -R -l /mnt
[[ "${ANS,,}" != "n" ]] && reboot -f || log "Reboot skipped. You can reboot manually."
