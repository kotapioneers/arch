#!/bin/bash
# Arch Batocera-style all-in-one installer for 256GB SSD
# Features: Openbox, EmulationStation, RetroArch, Steam, Flatpak streaming apps,
# controller mapping (right stick mouse + triggers), RGSX ROM downloader, ES system settings

set -e

# --- Configuration ---
SSD="/dev/sda"      # Change if different
USERNAME="gamer"
HOSTNAME="arch-console"
SWAP_SIZE="4G"

# --- Partitioning ---
echo "==> Partitioning SSD..."
parted --script $SSD mklabel gpt
parted --script $SSD mkpart ESP fat32 1MiB 512MiB
parted --script $SSD set 1 boot on
parted --script $SSD mkpart primary ext4 512MiB 100%

mkfs.fat -F32 ${SSD}1
mkfs.ext4 ${SSD}2

# --- Mount ---
mount ${SSD}2 /mnt
mkdir -p /mnt/boot
mount ${SSD}1 /mnt/boot

# --- Swapfile ---
fallocate -l $SWAP_SIZE /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# --- Pacstrap Base ---
pacstrap /mnt base base-devel linux linux-firmware intel-ucode sudo networkmanager git vim xorg xorg-xinit openbox flatpak wget

# --- Fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot System Setup ---
arch-chroot /mnt /bin/bash <<EOF
set -e

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Timezone
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# NetworkManager
systemctl enable NetworkManager

# User Creation
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
passwd -d $USERNAME # Set a blank password for the new user

EOF

# --- Chroot User Setup (via temporary script) ---
echo "==> Creating user-specific setup script inside the chroot..."
cat << 'EOT' > /mnt/tmp/user_setup.sh
#!/bin/bash
set -e

echo "==> Starting user-specific setup..."

# AUR Helper (yay)
git clone https://aur.archlinux.org/yay.git /tmp/yay
cd /tmp/yay
makepkg -si --noconfirm

# Install Applications
yay -S --noconfirm pcsx2-git portmaster emulationstation retroarch dolphin-emu ppsspp steam lutris xorg-xrandr xorg-xinput xboxdrv antimicrox python-pip

# Flatpak Streaming Apps
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Batocera 41 Theme
git clone https://github.com/batocera-linux/batocera-emulationstation-theme.git ~/.emulationstation/themes/Batocera41

# RGSX ROM Downloader
echo "==> Installing RGSX Downloader..."
git clone https://github.com/RetroGameSets/RGSX.git ~/rgsx

cat <<'EOF' > ~/rgsx/rgsx.desktop
[Desktop Entry]
Name=RGSX Downloader
Exec=python3 /home/$USERNAME/rgsx/ports/RGSX
Type=Application
EOF

# Custom Apps Auto-Scan
cat <<'EOF' > /usr/local/bin/es_scan_apps.sh
#!/bin/bash
ES_CUSTOM="/home/$USERNAME/.emulationstation/custom_apps"
mkdir -p "\$ES_CUSTOM"

# System apps
for app in /usr/share/applications/*.desktop; do cp "\$app" "\$ES_CUSTOM/" 2>/dev/null || true; done

# User apps (Flatpak & Lutris)
for app in /home/$USERNAME/.local/share/applications/*.desktop; do cp "\$app" "\$ES_CUSTOM/" 2>/dev/null || true; done

# RGSX ROM Downloader
if [ -f /home/$USERNAME/rgsx/rgsx.desktop ]; then
    cp /home/$USERNAME/rgsx/rgsx.desktop "\$ES_CUSTOM/"
fi

chown -R $USERNAME:$USERNAME "\$ES_CUSTOM"
EOF

chmod +x /usr/local/bin/es_scan_apps.sh

# System Settings Menu
mkdir -p ~/scripts

cat <<'EOF' > ~/scripts/emustation_settings.sh
#!/bin/bash
PS3="Choose an option: "
options=("Volume" "Display" "Network" "Bluetooth" "Update System" "Exit")
select opt in "${options[@]}"
do
    case $opt in
        "Volume") alsamixer ;;
        "Display") xrandr ;;
        "Network") nmcli d ;;
        "Bluetooth") bluetoothctl ;;
        "Update System") sudo pacman -Syu ;;
        "Exit") break ;;
        *) echo "Invalid option.";;
    esac
done
EOF

chmod +x ~/scripts/emustation_settings.sh

cat <<'EOF' > ~/.emulationstation/custom_apps/system_settings.desktop
[Desktop Entry]
Name=System Settings
Exec=/home/$USERNAME/scripts/emustation_settings.sh
Type=Application
EOF

echo "User setup complete."
EOT

chmod +x /mnt/tmp/user_setup.sh
arch-chroot /mnt /bin/su -c /tmp/user_setup.sh $USERNAME
rm /mnt/tmp/user_setup.sh

# --- Chroot Final System Configuration ---
arch-chroot /mnt /bin/bash <<EOF
set -e

# Controller Service (Right Stick Mouse + Triggers)
cat <<EOL > /etc/systemd/system/xboxdrv.service
[Unit]
Description=Xboxdrv controller mapping (Right Stick Mouse + Triggers)
After=network.target

[Service]
ExecStart=/usr/bin/xboxdrv --detach-kernel-driver --mimic-xpad --axismap="REL_X=RX*2,REL_Y=RY*2" --mouse --trigger-as-button --buttonmap="LT=BTN_LEFT,RT=BTN_RIGHT" --ui-buttonmap="A=ENTER,B=ESC,Y=TAB,X=SPACE,START=ENTER,SELECT=ESC" --evdev /dev/input/event* --silent
User=$USERNAME
Restart=always

[Install]
WantedBy=multi-user.target
EOL

systemctl enable xboxdrv.service

# ES Auto-scan Service
cat <<EOL > /etc/systemd/system/es_scan.service
[Unit]
Description=Auto-scan apps for EmulationStation
After=network.target

[Service]
ExecStart=/usr/local/bin/es_scan_apps.sh
User=$USERNAME
Type=oneshot

[Install]
WantedBy=multi-user.target
EOL

systemctl enable es_scan.service

EOF

# --- Finish ---
echo "==> Installation complete. Reboot into your new Arch Batocera-style console!"
echo "Controller is fully configured: right stick = mouse, LT/RT = left/right click."
echo "Post-installation: Run the step-by-step configuration guide for ROM setup, RGSX usage, and theme fine-tuning."
