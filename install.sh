#!/bin/bash
# ============================================================
# Arch Linux ZEN Gaming Auto-Installer — One-File Version
# Fully hands-off until password prompts, with reboot confirm.
# ============================================================

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Failed at line $LINENO"; exit 1' ERR

# ---------- helper functions ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
WARNINGS=0
log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; : $((WARNINGS++)); }
die(){ echo -e "${RED}[ERROR]${NC} $*" 1>&2; exit 1; }

# ---------- require root ----------
[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

# ---------- ensure disk variable set ----------
[[ -n "${INSTALL_DISK:-}" ]] || die "Set INSTALL_DISK (e.g. export INSTALL_DISK=/dev/nvme0n1)"
[[ -b "$INSTALL_DISK" ]] || die "Block device $INSTALL_DISK not found."

# ---------- passwords first ----------
read -rs -p "Set password for user 'lied': " userpass; echo
read -rs -p "Confirm password: " userpass2; echo
[[ "$userpass" == "$userpass2" && -n "$userpass" ]] || die "Passwords do not match or empty."

read -rp "Set a root password? [y/N] " setroot
if [[ "$setroot" =~ ^[Yy]$ ]]; then
    read -rs -p "Root password: " rootpass; echo
    read -rs -p "Confirm root password: " rootpass2; echo
    [[ "$rootpass" == "$rootpass2" && -n "$rootpass" ]] || die "Root passwords do not match or empty."
fi

# ---------- pre-disable fallback before installing kernel ----------
log "Pre-disabling mkinitcpio fallback images"
mkdir -p /etc/mkinitcpio.d
touch /etc/mkinitcpio.d/linux-zen.preset
cat > /etc/mkinitcpio.d/linux-zen.preset <<'EOF'
PRESETS=('default')
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-zen"
default_image="/boot/initramfs-linux-zen.img"
default_options=""
EOF

# ---------- wipe + partition ----------
timedatectl set-ntp true
log "Wiping $INSTALL_DISK"
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
mkfs.xfs -f "$ROOT_PART"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# ---------- base install ----------
log "Installing base system"
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
    networkmanager sudo nano git efibootmgr

genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/\<relatime\>/noatime/g' /mnt/etc/fstab || true

# ---------- chroot and configure ----------
arch-chroot /mnt /bin/bash <<EOFCHROOT
set -Eeuo pipefail

# Locale & time
echo "gaming-rig" > /etc/hostname
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "KEYMAP=uk" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

systemctl enable NetworkManager

# Users
useradd -m -G wheel,audio,video,storage,power,network,optical,scanner,rfkill -s /bin/bash lied
echo "lied:${userpass}" | chpasswd
if [[ "$setroot" =~ ^[Yy]$ ]]; then
    echo "root:${rootpass}" | chpasswd
else
    passwd -l root
fi
echo "lied ALL=(ALL) ALL" >> /etc/sudoers

# Main packages (no printers, no OBS)
pacman -Syu --noconfirm
pacman -S --noconfirm \
    intel-ucode \
    nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
    wayland wayland-protocols xdg-utils xdg-user-dirs \
    xdg-desktop-portal xdg-desktop-portal-hyprland \
    xorg-xwayland hyprland hyprpaper hyprcursor \
    wl-clipboard grim slurp swappy wf-recorder \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
    bluez bluez-utils blueman \
    polkit-gnome sddm \
    firefox discord \
    thunar thunar-archive-plugin thunar-volman tumbler ffmpegthumbnailer gvfs gvfs-mtp udisks2 polkit \
    wofi cliphist hypridle hyprlock mako \
    neovim git curl wget unzip unrar p7zip rsync htop fastfetch fzf ripgrep fd bat eza tree \
    zsh starship zsh-autosuggestions zsh-syntax-highlighting \
    ttf-jetbrains-mono-nerd noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-roboto \
    papirus-icon-theme gtk3 gtk4 qt6-base qt6-wayland qt5-base qt5-wayland kvantum \
    gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav \
    gst-vaapi libva libva-utils vulkan-icd-loader vulkan-tools vulkan-nvidia \
    lib32-vulkan-icd-loader lib32-vulkan-nvidia \
    steam wine wine-mono wine-gecko lutris protontricks gamemode lib32-gamemode \
    mangohud lib32-mangohud vkbasalt lib32-vkbasalt gamescope goverlay nvtop \
    flatpak ntfs-3g nvme-cli xfsprogs btrfs-progs dosfstools \
    cpupower lm_sensors thermald irqbalance zram-generator avahi nfs-utils

# Yay AUR helper
pacman -S --noconfirm --needed git base-devel
sudo -u lied bash -c 'git clone https://aur.archlinux.org/yay.git ~/yay && cd ~/yay && makepkg -si --noconfirm'

# AUR packages
sudo -u lied yay -S --noconfirm --needed \
    nvidia-vaapi-driver dxvk-bin dxvk-nvapi heroic-games-launcher-bin \
    obs-vkcapture ghostty-bin openasar-bin equicord \
    catppuccin-ghostty-git catppuccin-gtk-theme-mocha catppuccin-kvantum-theme-git catppuccin-cursors catppuccin-sddm-theme-git

# NVIDIA initramfs settings (fallback already disabled)
sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf
echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia-kms.conf
mkinitcpio -P

# Bootloader
bootctl install
ROOT_UUID=\$(blkid -s PARTUUID -o value $ROOT_PART)
ROOT_FS=\$(findmnt -no FSTYPE /)
cat > /boot/loader/loader.conf <<'EOFBOOT'
timeout 0
default arch-linux-zen
editor no
EOFBOOT
cat > /boot/loader/entries/arch-linux-zen.conf <<EOFBOOT
title Arch Linux Zen (Gaming)
linux /vmlinuz-linux-zen
initrd /intel-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=\${ROOT_UUID} rw rootfstype=\${ROOT_FS} nvidia_drm.modeset=1 nvidia_drm.fbdev=1
EOFBOOT

# Enable services
systemctl enable NetworkManager bluetooth sddm thermald irqbalance fstrim.timer avahi-daemon cpupower nvidia-persistenced nvidia-powerd

# THEME mako + anime
sudo -u lied mkdir -p /home/lied/Pictures/Wallpapers
sudo -u lied curl -fsSL -o /home/lied/Pictures/Wallpapers/anime-dark-1.jpg https://images.unsplash.com/photo-1519681393784-d120267933ba?q=80&w=2560&auto=format&fit=crop
sudo -u lied mkdir -p /home/lied/.config/mako
cat > /home/lied/.config/mako/config <<'EOFMAKO'
background-color=#1e1e2e
text-color=#cdd6f4
border-color=#89b4fa
border-size=2
default-timeout=5000
font=Noto Sans 11
EOFMAKO

# Auto login to graphical
systemctl set-default graphical.target

EOFCHROOT

# ---------- finish ----------
log "Installation complete."
echo "========================================"
echo "Logs saved to: /var/log/installer.log"
echo "========================================"
read -rp "Press Y to reboot now, or any other key to cancel: " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  umount -R /mnt
  reboot
else
  log "Not rebooting. System ready."
fi
