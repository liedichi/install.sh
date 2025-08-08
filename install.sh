#!/bin/bash
# ============================================================
# Arch Linux minimal Hyprland/NVIDIA setup (linux-zen, no fallback)
# Hostname: Terra • User: lied • DM: SDDM • Apps: Hyprland, Firefox, Ghostty
# ============================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Failed at line $LINENO"; exit 1' ERR
log(){ echo -e "\033[0;32m[$(date +'%F %T')]\033[0m $*"; }
die(){ echo -e "\033[0;31m[ERROR]\033[0m $*" 1>&2; exit 1; }

# --- prerequisites & input ---
(( EUID == 0 )) || die "Run as root."
[[ -n "${INSTALL_DISK:-}" ]] || die "Set INSTALL_DISK (e.g. /dev/nvme0n1)."
[[ -b "$INSTALL_DISK"      ]] || die "Block device $INSTALL_DISK not found."

read -rs -p "Password for user 'lied': " PW1; echo
read -rs -p "Confirm password: " PW2; echo
[[ -n "$PW1" && "$PW1" == "$PW2" ]] || die "Passwords empty/mismatch."
read -rp "Set a root password too? [y/N] " SETROOT
if [[ "${SETROOT,,}" == "y" ]]; then
  read -rs -p "Root password: " RPW1; echo
  read -rs -p "Confirm root password: " RPW2; echo
  [[ -n "$RPW1" && "$RPW1" == "$RPW2" ]] || die "Root passwords empty/mismatch."
fi

timedatectl set-ntp true || true

# --- partition & format: EFI + XFS root ---
log "Wiping and partitioning $INSTALL_DISK"
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

# --- base system ---
log "Installing base system"
pacstrap -K /mnt base linux-firmware networkmanager sudo nano git curl wget efibootmgr openssh

genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/\<relatime\>/noatime/g' /mnt/etc/fstab || true

# pass secrets into chroot
printf '%s' "$PW1" > /mnt/root/.pw_lied
[[ "${SETROOT,,}" == "y" ]] && printf '%s' "$RPW1" > /mnt/root/.pw_root

# --- chroot do-everything ---
log "Entering target system…"
arch-chroot /mnt /bin/bash <<'CHROOT'
set -Eeuo pipefail

# Enable multilib and refresh big-time
if ! grep -Eq '^\s*\[multilib\]' /etc/pacman.conf; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi
pacman -Syyu --noconfirm

# Make sure mkinitcpio exists & has a base config
pacman -S --noconfirm mkinitcpio
[[ -f /etc/mkinitcpio.conf ]] || install -Dm644 /usr/share/mkinitcpio/mkinitcpio.conf /etc/mkinitcpio.conf

# Basics
echo "Terra" > /etc/hostname
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "KEYMAP=uk" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# User
id -u lied &>/dev/null || useradd -m -G wheel,audio,video,storage,network -s /bin/bash lied
printf 'lied:%s\n' "$(cat /root/.pw_lied)" | chpasswd
rm -f /root/.pw_lied
if [[ -f /root/.pw_root ]]; then
  printf 'root:%s\n' "$(cat /root/.pw_root)" | chpasswd; rm -f /root/.pw_root
else
  passwd -l root || true
fi
echo "lied ALL=(ALL) ALL" >> /etc/sudoers

# ---- Linux-zen WITHOUT fallback ----
# Prepare preset that only builds the 'default' image
mkdir -p /etc/mkinitcpio.d
cat > /etc/mkinitcpio.d/linux-zen.preset <<'PRESET'
ALL_config="/etc/mkinitcpio.conf"
PRESETS=('default')
default_image="/boot/initramfs-linux-zen.img"
PRESET

# NVIDIA early KMS & hooks in mkinitcpio
sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf || true
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf || true
echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'BL'
blacklist nouveau
options nouveau modeset=0
BL

# Install kernel & headers (no fallback will be created)
pacman -S --noconfirm linux-zen linux-zen-headers

# Core runtime packages (only what we need)
pacman -S --noconfirm \
  intel-ucode \
  nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils \
  wayland xorg-xwayland \
  hyprland xdg-desktop-portal xdg-desktop-portal-hyprland \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  firefox \
  sddm qt6-wayland \
  polkit-gnome \
  wl-clipboard \
  xdg-user-dirs

# Build the one initramfs (default only)
rm -f /boot/initramfs-linux-zen-fallback.img || true
mkinitcpio -P

# systemd-boot
bootctl install --esp-path=/boot || true
ROOT_UUID=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE /)")
ROOT_FS=$(findmnt -no FSTYPE /)
cat > /boot/loader/loader.conf <<'L'
timeout 0
default arch-linux-zen
editor no
L
cat > /boot/loader/entries/arch-linux-zen.conf <<EOF
title Arch Linux Zen
linux /vmlinuz-linux-zen
initrd /intel-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=${ROOT_UUID} rw rootfstype=${ROOT_FS} nvidia_drm.modeset=1 nvidia_drm.fbdev=1
EOF
bootctl update || true

# Networking + DM
systemctl enable NetworkManager.service
systemctl enable sddm.service
systemctl set-default graphical.target

# Hyprland minimal user session helpers
runuser -l lied -c 'xdg-user-dirs-update || true'
mkdir -p /etc/xdg/autostart
# Polkit agent for GUI auth
cat > /etc/xdg/autostart/polkit-gnome-auth-agent.desktop <<'E'
[Desktop Entry]
Type=Application
Name=Polkit Agent
Exec=/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
OnlyShowIn=GNOME;KDE;LXQt;LXDE;MATE;XFCE;Hyprland;
E

# --- AUR: ghostty ---
pacman -S --needed --noconfirm base-devel git
runuser -l lied -c 'mkdir -p $HOME/.cache/yay && cd $HOME/.cache/yay && rm -rf yay-bin && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm'
runuser -l lied -c 'yay -S --needed --noconfirm ghostty-bin'

CHROOT

# --- wrap up ---
echo
echo "========================================"
echo "Install complete. Hostname: Terra"
echo "========================================"
read -rp "Reboot now? [Y/n] " ANS
sync
umount -R /mnt || umount -R -l /mnt
[[ "${ANS,,}" != "n" ]] && reboot -f || log "Reboot skipped. You can reboot manually."
