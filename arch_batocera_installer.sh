#!/bin/bash
# Robust Arch Batocera-style all-in-one installer for 256GB SSD
# Features: Openbox, EmulationStation, RetroArch, Steam, Lutris,
# controller mapping (right stick mouse + triggers), RGSX ROM downloader, ES system settings
# Adds: GRUB install (UEFI), multilib enable, microcode auto-detect, xpad blacklist

set -euo pipefail

# --- Configuration (edit before running) ---
SSD="/dev/sda"      # Change if different - THIS WILL BE WIPED
USERNAME="gamer"
HOSTNAME="arch-console"
SWAP_SIZE="4G"
TIMEZONE="Asia/Kolkata"
LOCALE="en_US.UTF-8"

# --- Sanity checks ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root from the Arch live ISO."
  exit 1
fi

if ! lsblk -no NAME "$SSD" >/dev/null 2>&1; then
  echo "Error: $SSD not found. Run 'lsblk' and update SSD variable."
  exit 1
fi

if ! ping -c 2 archlinux.org >/dev/null 2>&1; then
  echo "Network appears down — set up networking and rerun."
  exit 1
fi

# --- Partitioning ---
echo "==> Partitioning $SSD..."
parted --script "$SSD" mklabel gpt
parted --script "$SSD" mkpart ESP fat32 1MiB 512MiB
parted --script "$SSD" set 1 boot on
parted --script "$SSD" mkpart primary ext4 512MiB 100%

mkfs.fat -F32 "${SSD}1"
mkfs.ext4 "${SSD}2"

mount "${SSD}2" /mnt
mkdir -p /mnt/boot
mount "${SSD}1" /mnt/boot

# --- Swap ---
fallocate -l "$SWAP_SIZE" /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# --- Base system ---
pacstrap /mnt base base-devel linux linux-firmware sudo networkmanager git vim \
  xorg xorg-xinit openbox wget curl bash-completion

genfstab -U /mnt >> /mnt/etc/fstab

# --- Blacklist xpad ---
cat > /mnt/etc/modprobe.d/blacklist-xpad.conf <<EOF
blacklist xpad
EOF

# --- Microcode ---
CPU_VENDOR="$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | tr -d '[:space:]' || true)"
MICROCODE_PKG="intel-ucode"
if echo "$CPU_VENDOR" | grep -qi "AuthenticAMD"; then
  MICROCODE_PKG="amd-ucode"
fi
echo "==> Detected CPU vendor: ${CPU_VENDOR:-unknown}, using ${MICROCODE_PKG}"

# --- Chroot base setup ---
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
pacman -S --noconfirm flatpak
pacman -Scc --noconfirm
EOF

chmod +x /mnt/root/chroot_setup.sh
arch-chroot /mnt /root/chroot_setup.sh
rm -f /mnt/root/chroot_setup.sh

# --- User setup script ---
cat > /mnt/home/$USERNAME/user_setup.sh <<'EOS'
#!/bin/bash
set -euo pipefail
USERNAME_ENV=$(whoami)

# yay
git clone https://aur.archlinux.org/yay.git /tmp/yay
cd /tmp/yay
makepkg -si --noconfirm

# Packages
yay -S --noconfirm pcsx2-git portmaster emulationstation retroarch dolphin-emu ppsspp \
  steam lutris xorg-xrandr xorg-xinput xboxdrv antimicrox python-pip

# Theme
mkdir -p /home/$USERNAME_ENV/.emulationstation/themes
git clone https://github.com/batocera-linux/batocera-emulationstation-theme.git \
  /home/$USERNAME_ENV/.emulationstation/themes/Batocera41 || true

# RGSX
git clone https://github.com/RetroGameSets/RGSX.git /home/$USERNAME_ENV/rgsx || true
cat > /home/$USERNAME_ENV/rgsx/rgsx.desktop <<EOF
[Desktop Entry]
Name=RGSX Downloader
Exec=python3 /home/$USERNAME_ENV/rgsx/ports/RGSX
Type=Application
EOF

# System settings
mkdir -p /home/$USERNAME_ENV/scripts
cat > /home/$USERNAME_ENV/scripts/emustation_settings.sh <<EOF
#!/bin/bash
PS3="Choose an option: "
options=("Volume" "Display" "Network" "Bluetooth" "Update System" "Exit")
select opt in "\${options[@]}"; do
  case \$opt in
    "Volume") alsamixer ;;
    "Display") xrandr ;;
    "Network") nmcli d ;;
    "Bluetooth") bluetoothctl ;;
    "Update System") sudo pacman -Syu ;;
    "Exit") break ;;
  esac
done
EOF
chmod +x /home/$USERNAME_ENV/scripts/emustation_settings.sh

mkdir -p /home/$USERNAME_ENV/.emulationstation/custom_apps
cat > /home/$USERNAME_ENV/.emulationstation/custom_apps/system_settings.desktop <<EOF
[Desktop Entry]
Name=System Settings
Exec=/home/$USERNAME_ENV/scripts/emustation_settings.sh
Type=Application
EOF

# Steam + Lutris menu entries
cat > /home/$USERNAME_ENV/.emulationstation/custom_apps/steam.desktop <<EOF
[Desktop Entry]
Name=Steam
Exec=steam
Type=Application
EOF

cat > /home/$USERNAME_ENV/.emulationstation/custom_apps/lutris.desktop <<EOF
[Desktop Entry]
Name=Lutris
Exec=lutris
Type=Application
EOF

chown -R $USERNAME_ENV:$USERNAME_ENV /home/$USERNAME_ENV/.emulationstation /home/$USERNAME_ENV/scripts /home/$USERNAME_ENV/rgsx
EOS

chmod +x /mnt/home/$USERNAME/user_setup.sh
arch-chroot /mnt /bin/su - $USERNAME -c "/home/$USERNAME/user_setup.sh"
rm -f /mnt/home/$USERNAME/user_setup.sh

# --- Final chroot config ---
cat > /mnt/root/finalize_chroot.sh <<EOF
#!/bin/bash
set -euo pipefail
USERNAME="$USERNAME"

cat > /etc/systemd/system/xboxdrv.service <<SERVICE
[Unit]
Description=Xboxdrv controller mapping
After=network.target
[Service]
ExecStart=/usr/bin/xboxdrv --detach-kernel-driver --mimic-xpad \
  --axismap="REL_X=RX*2,REL_Y=RY*2" --mouse --trigger-as-button \
  --buttonmap="LT=BTN_LEFT,RT=BTN_RIGHT" \
  --ui-buttonmap="A=ENTER,B=ESC,Y=TAB,X=SPACE,START=ENTER,SELECT=ESC" \
  --silent
User=\$USERNAME
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable xboxdrv.service
EOF

chmod +x /mnt/root/finalize_chroot.sh
arch-chroot /mnt /root/finalize_chroot.sh
rm -f /mnt/root/finalize_chroot.sh

echo "==> Installation complete. Reboot now."

echo "==> Installation complete. Important next steps before first boot:"
echo " 1) Reboot the machine: reboot"
echo " 2) On first boot, change the default user password: passwd $USERNAME"
echo " 3) If controller issues appear, check 'rmmod xpad' and logs: journalctl -u xboxdrv.service"
echo " 4) If Steam fails, ensure multilib is enabled and run: sudo pacman -Syu"
echo
echo "Rebooting now..."
sync
reboot
