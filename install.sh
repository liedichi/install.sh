/usr/local/bin/build-cachy-kernel << 'EOF'
#!/bin/bash
set -e

KERNEL_DIR="/usr/src/linux"
CONFIG_BACKUP="/etc/kernels/kernel-config-LiedsOS"

echo "Building LiedsOS Cachy-RT-BORE kernel..."

cd "$KERNEL_DIR"

# Download latest CachyOS patches
echo "Downloading CachyOS patches..."
rm -rf /tmp/cachy-patches*
cd /tmp
wget -q https://github.com/CachyOS/kernel-patches/archive/master.zip
unzip -q master.zip

# Detect kernel version
KERNEL_VERSION=$(cd "$KERNEL_DIR" && make kernelversion | cut -d. -f1-2)
echo "Kernel version: $KERNEL_VERSION"

# Find matching patch directory
if [ -d "kernel-patches-master/$KERNEL_VERSION" ]; then
    PATCH_DIR="$KERNEL_VERSION"
elif [ -d "kernel-patches-master/6.12" ]; then
    PATCH_DIR="6.12"
elif [ -d "kernel-patches-master/6.11" ]; then
    PATCH_DIR="6.11"
else
    PATCH_DIR=$(ls kernel-patches-master/ | grep "^6\." | sort -V | tail -1)
fi

echo "Using patches from: $PATCH_DIR"

cd "$KERNEL_DIR"

# Reset any previous patches
git checkout . 2>/dev/null || true

# Apply CachyOS patches
if [ -f "/tmp/kernel-patches-master/$PATCH_DIR/sched/0001-BORE.patch" ]; then
    echo "Applying BORE scheduler..."
    patch -p1 < "/tmp/kernel-patches-master/$PATCH_DIR/sched/0001-BORE.patch" || true
fi

if [ -f "/tmp/kernel-patches-master/$PATCH_DIR/0001-cachyos-base.patch" ]; then
    echo "Applying CachyOS base optimizations..."
    patch -p1 < "/tmp/kernel-patches-master/$PATCH_DIR/0001-cachyos-base.patch" || true
fi

# Restore saved configuration or create new one
if [ -f "$CONFIG_BACKUP" ]; then
    echo "Restoring LiedsOS configuration..."
    cp "$CONFIG_BACKUP" .config
    make olddefconfig
else
    echo "Creating new LiedsOS configuration..."
    # Use the config from our guide
    cat > .config << 'KCONFIG'
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_LOCALVERSION="-LiedsOS"
CONFIG_LOCALVERSION_AUTO=n
CONFIG_PREEMPT_RT=y
CONFIG_PREEMPT=y
CONFIG_SCHED_BORE=y
CONFIG_HZ_1000=y
CONFIG_HZ=1000
# Add other essential configs here
KCONFIG
    make olddefconfig
fi

# Build kernel
echo "Compiling LiedsOS kernel..."
chrt -f 99 make -j24
make modules_install
cp arch/x86/boot/bzImage /efi/vmlinuz-LiedsOS

# Save configuration
cp .config "$CONFIG_BACKUP"

# Cleanup
rm -rf /tmp/cachy-patches* /tmp/kernel-patches-master*

echo "LiedsOS Cachy-RT-BORE kernel build complete!"
EOF

chmod +x /usr/local/bin/build-cachy-kernel

# Set up automatic rebuilds when rt-sources updates
mkdir -p /etc/portage/env/sys-kernel
cat > /etc/portage/env/sys-kernel/rt-sources << 'EOF'
post_pkg_postinst() {
    einfo "Auto-rebuilding LiedsOS Cachy-RT-BORE kernel..."
    /usr/local/bin/build-cachy-kernel
}
EOF
