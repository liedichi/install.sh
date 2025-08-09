#!/bin/bash
set -Eeuo pipefail
trap 'echo -e "\e[31m[ERROR]\e[0m failed at line $LINENO"; exit 1' ERR

log(){ echo -e "\e[32m[$(date +'%F %T')]\e[0m $*"; }
die(){ echo -e "\e[31m[ERROR]\e[0m $*" 1>&2; exit 1; }

# ---- sanity ----
(( EUID == 0 )) || die "Run as root."
[[ -n "${INSTALL_DISK:-}" ]] || die "Set INSTALL_DISK (e.g. /dev/nvme0n1)."
[[ -b "$INSTALL_DISK"      ]] || die "Block device $INSTALL_DISK not found."

# ---- password prompts ----
read -rs -p "Password for user 'lied': " PW1; echo
read -rs -p "Confirm password: " PW2; echo
[[ -n "$PW1" && "$PW1" == "$PW2" ]] || die "Passwords empty/mismatch."
read -rp "Set a root password too? [y/N] " SETROOT
if [[ "${SETROOT,,}" == "y" ]]; then
  read -rs -p "Root password: " RPW1; echo
  read -rs -p "Confirm root password: " RPW2; echo
  [[ -n "$RPW1" && "$RPW1" == "$RPW2" ]] || die "Root passwords empty/mismatch."
fi

# ---- partition + format (EFI + XFS) ----
timedatectl set-ntp true || true
log "Partitioning $INSTALL_DISK"
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

# ---- base system ----
log "Installing base system"
pacstrap -K /mnt base linux-firmware networkmanager sudo nano git curl wget efibootmgr openssh mkinitcpio

genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/\<relatime\>/noatime/g' /mnt/etc/fstab || true

# pass secrets into target
printf '%s' "$PW1" > /mnt/root/.pw_lied
[[ "${SETROOT,,}" == "y" ]] && printf '%s' "$RPW1" > /mnt/root/.pw_root

# ---- chroot configure ----
log "Configuring target (chroot)…"
arch-chroot /mnt /bin/bash <<'CHROOT'
set -Eeuo pipefail

# enable multilib and refresh
if ! grep -Eq '^\s*\[multilib\]' /etc/pacman.conf; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi
pacman -Syy --noconfirm

# hostname, locale, time
echo "Terra" > /etc/hostname
sed -i 's/^#\(en_GB.UTF-8 UTF-8\)/\1/' /etc/locale.gen || echo "en_GB.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
printf "LANG=en_GB.UTF-8\n" > /etc/locale.conf
printf "KEYMAP=uk\n" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# user + sudo
id -u lied &>/dev/null || useradd -m -G wheel,audio,video,storage,network -s /bin/bash lied
printf 'lied:%s\n' "$(cat /root/.pw_lied)" | chpasswd && rm -f /root/.pw_lied
if [[ -f /root/.pw_root ]]; then
  printf 'root:%s\n' "$(cat /root/.pw_root)" | chpasswd && rm -f /root/.pw_root
else
  passwd -l root || true
fi
echo "lied ALL=(ALL) ALL" > /etc/sudoers.d/10-lied

# blacklist nouveau early (quiet boot, make sure nvidia loads)
install -Dm644 /dev/stdin /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

# mkinitcpio: NVIDIA kms modules + hooks
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf || true
sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf || true
echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf

# write preset BEFORE kernel so only default image exists
mkdir -p /etc/mkinitcpio.d
install -Dm644 /dev/stdin /etc/mkinitcpio.d/linux-zen.preset <<'EOF'
ALL_config="/etc/mkinitcpio.conf"
PRESETS=('default')
default_image="/boot/initramfs-linux-zen.img"
EOF

# kernel + microcode
pacman -S --noconfirm linux-zen linux-zen-headers intel-ucode

# desktop stack (minimal but complete)
pacman -S --noconfirm \
  hyprland xorg-xwayland \
  xdg-utils xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-hyprland \
  qt6-base qt5-wayland qt6-wayland \
  sddm firefox ghostty \
  nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils \
  wl-clipboard \
  pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol \
  polkit-gnome \
  hyprpaper hypridle \
  noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd

# initramfs (no fallback)
rm -f /boot/initramfs-linux-zen-fallback.img || true
mkinitcpio -P

# bootloader (systemd-boot)
bootctl install --esp-path=/boot || true
ROOT_UUID=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE /)")
ROOT_FS=$(findmnt -no FSTYPE /)
install -Dm644 /dev/stdin /boot/loader/loader.conf <<'EOF'
timeout 0
default arch-linux-zen
editor no
EOF
install -Dm644 /dev/stdin /boot/loader/entries/arch-linux-zen.conf <<EOF
title Arch Linux Zen
linux /vmlinuz-linux-zen
initrd /intel-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=${ROOT_UUID} rw rootfstype=${ROOT_FS} nvidia_drm.modeset=1 nvidia_drm.fbdev=1
EOF

# QoL: start agents on login (SDDM session scripts are fine later; for now polkit agent is available)
# services
systemctl enable NetworkManager sddm

CHROOT

# wrap up
read -rp "Reboot now? [Y/n] " A
sync
umount -R /mnt || umount -R -l /mnt
[[ "${A,,}" == "n" ]] || reboot -f
