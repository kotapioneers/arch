#!/bin/bash
# Robust Arch Batocera-style all-in-one installer for 256GB SSD
# Features: Openbox, EmulationStation, RetroArch, Steam, Lutris
# Controller mapping (right stick mouse + triggers), RGSX ROM downloader
# Adds: GRUB install (UEFI), multilib enable, microcode auto-detect
# Radeon disabled, Intel forced

set -euo pipefail

# --- Configuration ---
SSD="/dev/sda"      # Change if different - THIS WILL BE WIPED
USERNAME="gamer"
HOSTNAME="arch-console"
SWAP_SIZE="4G"
TIMEZONE="Asia/Kolkata"
LOCALE="en_US.UTF-8"

# --- Checks ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root from the Arch live ISO."
  exit 1
fi

if ! lsblk -no NAME "$SSD" >/dev/null 2>&1; then
  echo "Error: $SSD not found. Run 'lsblk' and update SSD variable."
  exit 1
fi

if ! ping -c 2 archlinux.org >/dev/null 2>&1; then
  echo "No network. Setup networking first."
  exit 1
fi

# --- Partition ---
parted --script "$SSD" mklabel gpt
parted --script "$SSD" mkpart ESP fat32 1MiB 512MiB
parted --script "$SSD" set 1 boot on
parted --script "$SSD" mkpart primary ext4 512MiB 100%

# --- Format ---
mkfs.fat -F32 "${SSD}1"
mkfs.ext4 "${SSD}2"

# --- Mount ---
mount "${SSD}2" /mnt
mkdir -p /mnt/boot
mount "${SSD}1" /mnt/boot

# --- Swapfile ---
fallocate -l "$SWAP_SIZE" /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# --- Base Install ---
pacstrap /mnt base base-devel linux linux-firmware sudo networkmanager git vim \
  xorg xorg-xinit openbox wget curl bash-completion mesa mesa-demos

# --- Fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Blacklist xpad ---
cat > /mnt/etc/modprobe.d/blacklist-xpad.conf <<EOF
blacklist xpad
EOF

# --- Microcode ---
CPU_VENDOR="$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | tr -d '[:space:]')"
MICROCODE_PKG="intel-ucode"
if echo "$CPU_VENDOR" | grep -qi "AuthenticAMD"; then
  MICROCODE_PKG="amd-ucode"
fi

# --- Chroot Setup ---
cat > /mnt/root/chroot_setup.sh <<EOF
#!/bin/bash
set -euo pipefail
USERNAME="$USERNAME"
HOSTNAME="$HOSTNAME"
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
MICROCODE_PKG="$MICROCODE_PKG"

echo "\$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/\$TIMEZONE /etc/localtime
hwclock --systohc
sed -i "s/#\$LOCALE UTF-8/\$LOCALE UTF-8/" /etc/locale.gen || true
locale-gen
echo "LANG=\$LOCALE" > /etc/locale.conf
systemctl enable NetworkManager

useradd -m -G wheel -s /bin/bash "\$USERNAME"
echo "\$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
echo "\$USERNAME:\$USERNAME" | chpasswd

# multilib
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  cat >> /etc/pacman.conf <<EOM

[multilib]
Include = /etc/pacman.d/mirrorlist
EOM
fi
pacman -Sy --noconfirm

pacman -S --noconfirm "\$MICROCODE_PKG" grub efibootmgr dosfstools mtools

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg || true

systemctl enable fstrim.timer

EOF

chmod +x /mnt/root/chroot_setup.sh
arch-chroot /mnt /root/chroot_setup.sh
rm /mnt/root/chroot_setup.sh

# --- User Setup ---
cat > /mnt/tmp/user_setup.sh <<'USER_SCRIPT'
#!/bin/bash
set -euo pipefail
USERNAME_ENV="$1"

cd /home/$USERNAME_ENV
git clone https://aur.archlinux.org/yay.git /tmp/yay
chown -R "$USERNAME_ENV:$USERNAME_ENV" /tmp/yay
cd /tmp/yay
sudo -u "$USERNAME_ENV" makepkg -si --noconfirm

sudo -u "$USERNAME_ENV" yay -S --noconfirm pcsx2-git emulationstation retroarch dolphin-emu ppsspp steam lutris \
  xorg-xrandr xorg-xinput xboxdrv antimicrox

# Batocera theme
sudo -u "$USERNAME_ENV" bash -c 'mkdir -p ~/.emulationstation/themes && git clone https://github.com/batocera-linux/batocera-emulationstation-theme.git ~/.emulationstation/themes/Batocera41 || true'

# RGSX
sudo -u "$USERNAME_ENV" git clone https://github.com/RetroGameSets/RGSX.git /home/$USERNAME_ENV/rgsx || true

# Custom apps for Steam + Lutris
mkdir -p /home/$USERNAME_ENV/.emulationstation/custom_apps
cat > /home/$USERNAME_ENV/.emulationstation/custom_apps/steam.desktop <<EOL
[Desktop Entry]
Name=Steam
Exec=steam
Type=Application
EOL
cat > /home/$USERNAME_ENV/.emulationstation/custom_apps/lutris.desktop <<EOL
[Desktop Entry]
Name=Lutris
Exec=lutris
Type=Application
EOL
chown -R $USERNAME_ENV:$USERNAME_ENV /home/$USERNAME_ENV/.emulationstation

USER_SCRIPT

chmod +x /mnt/tmp/user_setup.sh
arch-chroot /mnt /bin/su - "$USERNAME" -c "/tmp/user_setup.sh $USERNAME"
rm -f /mnt/tmp/user_setup.sh

# --- Finalize ---
cat > /mnt/root/finalize_chroot.sh <<EOF
#!/bin/bash
set -euo pipefail
USERNAME="$USERNAME"

# Auto-login and start EmulationStation
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOL
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
EOL

echo '[[ -z \$DISPLAY && \$XDG_VTNR -eq 1 ]] && exec startx /usr/bin/emulationstation -- :0' >> /home/$USERNAME/.bash_profile
chown $USERNAME:$USERNAME /home/$USERNAME/.bash_profile

# Xboxdrv mapping
cat > /etc/systemd/system/xboxdrv.service <<SERVICE_EOF
[Unit]
Description=Xboxdrv controller mapping
After=network.target

[Service]
ExecStart=/usr/bin/xboxdrv --detach-kernel-driver --mimic-xpad --axismap="REL_X=RX*2,REL_Y=RY*2" --mouse --trigger-as-button --buttonmap="LT=BTN_LEFT,RT=BTN_RIGHT" --ui-buttonmap="A=ENTER,B=ESC,Y=TAB,X=SPACE,START=ENTER,SELECT=ESC" --evdev /dev/input/event* --silent
User=$USERNAME
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE_EOF
systemctl enable xboxdrv.service

# Force Intel GPU
echo "blacklist radeon" > /etc/modprobe.d/blacklist-radeon.conf
echo "blacklist amdgpu" >> /etc/modprobe.d/blacklist-radeon.conf
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-intel.conf <<EOL
Section "Device"
    Identifier "Intel Graphics"
    Driver "intel"
    BusID "PCI:0:2:0"
    Option "TearFree" "true"
EndSection
EOL
echo 'export DRI_PRIME=0' >> /home/$USERNAME/.bashrc
echo 'export LIBGL_ALWAYS_SOFTWARE=0' >> /home/$USERNAME/.bashrc
chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc

EOF

chmod +x /mnt/root/finalize_chroot.sh
arch-chroot /mnt /root/finalize_chroot.sh
rm /mnt/root/finalize_chroot.sh

echo "==> Install finished. Reboot to launch EmulationStation on Intel GPU only."
reboot
