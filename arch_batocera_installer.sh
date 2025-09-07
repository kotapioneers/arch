#!/bin/bash
# Arch Batocera-style all-in-one installer for 256GB SSD
# Features: Openbox, EmulationStation, RetroArch, Steam, Flatpak streaming apps, controller mapping, RGSX ROM downloader, ES system settings, right stick mouse with triggers for clicks

set -e

SSD="/dev/sda"  # Change if different
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
pacstrap /mnt base base-devel linux linux-firmware intel-ucode sudo networkmanager git vim xorg xorg-xinit openbox

# --- Fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot Setup ---
arch-chroot /mnt /bin/bash <<EOF

# Set hostname
echo $HOSTNAME > /etc/hostname

# Set timezone
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# NetworkManager enable
systemctl enable NetworkManager

# User creation
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# --- Install Emulators & Apps ---
pacman -S --noconfirm emulationstation retroarch dolphin-emu pcsx2 ppsspp steam lutris portmaster flatpak xorg-xrandr xorg-xinput xboxdrv antimicrox python-pip git wget

# --- Flatpak Streaming Apps ---
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
sudo -u $USERNAME flatpak install flathub com.spotify.Client -y
sudo -u $USERNAME flatpak install flathub com.netflix.MozillaNetflix -y
sudo -u $USERNAME flatpak install flathub com.google.Chrome -y
sudo -u $USERNAME flatpak install flathub tv.crunchyroll.Crunchyroll -y
sudo -u $USERNAME flatpak install flathub com.apple.TV -y
sudo -u $USERNAME flatpak install flathub com.disney.DisneyPlus -y

# --- Batocera 41 Theme ---
git clone https://github.com/batocera-linux/batocera-emulationstation-theme.git /home/$USERNAME/.emulationstation/themes/Batocera41
chown -R $USERNAME:$USERNAME /home/$USERNAME/.emulationstation

# --- Controller Setup (xboxdrv + right stick mouse + triggers for clicks) ---
cat <<EOL > /etc/systemd/system/xboxdrv.service
[Unit]
Description=Xboxdrv controller mapping
After=network.target

[Service]
ExecStart=/usr/bin/xboxdrv --detach-kernel-driver --daemon --mimic-xpad \
--trigger-as-button --ui-buttonmap="A=ENTER,B=ESC,Y=TAB,X=SPACE,START=ENTER,SELECT=ESC" \
--axismap="REL_X=RX,REL_Y=RY" --mouse \
--buttonmap="LT=BTN_LEFT,RT=BTN_RIGHT"
User=$USERNAME
Restart=always

[Install]
WantedBy=multi-user.target
EOL
systemctl enable xboxdrv.service

# --- RGSX ROM Downloader Installation ---
echo "==> Installing RGSX Downloader..."
sudo -u $USERNAME git clone https://github.com/yourusername/rgsx.git /home/$USERNAME/rgsx
cat <<EOL > /home/$USERNAME/rgsx/rgsx.desktop
[Desktop Entry]
Name=RGSX Downloader
Exec=python3 /home/$USERNAME/rgsx/rgsx.py
Type=Application
EOL
chown -R $USERNAME:$USERNAME /home/$USERNAME/rgsx /home/$USERNAME/rgsx/rgsx.desktop

# --- Custom Apps Auto-Scan Service ---
cat <<EOL > /usr/local/bin/es_scan_apps.sh
#!/bin/bash
ES_CUSTOM="/home/$USERNAME/.emulationstation/custom_apps"
mkdir -p "$ES_CUSTOM"

# System apps
for app in /usr/share/applications/*.desktop; do
  cp "\$app" "$ES_CUSTOM/" 2>/dev/null || true
 done

# User apps (Flatpak & Lutris)
for app in /home/$USERNAME/.local/share/applications/*.desktop; do
  cp "\$app" "$ES_CUSTOM/" 2>/dev/null || true
 done

# RGSX ROM Downloader
if [ -f /home/$USERNAME/rgsx/rgsx.desktop ]; then
  cp /home/$USERNAME/rgsx/rgsx.desktop "$ES_CUSTOM/"
fi

chown -R $USERNAME:$USERNAME "$ES_CUSTOM"
EOL
chmod +x /usr/local/bin/es_scan_apps.sh

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

# --- System Settings Menu for ES ---
mkdir -p /home/$USERNAME/scripts
cat <<EOL > /home/$USERNAME/scripts/emustation_settings.sh
#!/bin/bash
# Controller-friendly system settings menu
PS3="Choose an option: "
options=("Volume" "Display" "Network" "Bluetooth" "Update System" "Exit")
select opt in "${options[@]}"
do
  case \$opt in
    "Volume") alsamixer ;; 
    "Display") xrandr ;; 
    "Network") nmcli d ;; 
    "Bluetooth") bluetoothctl ;; 
    "Update System") sudo pacman -Syu ;; 
    "Exit") break ;;
    *) echo "Invalid option.";;
  esac
done
EOL
chmod +x /home/$USERNAME/scripts/emustation_settings.sh
cat <<EOL > /home/$USERNAME/.emulationstation/custom_apps/system_settings.desktop
[Desktop Entry]
Name=System Settings
Exec=/home/$USERNAME/scripts/emustation_settings.sh
Type=Application
EOL
chown -R $USERNAME:$USERNAME /home/$USERNAME/scripts /home/$USERNAME/.emulationstation/custom_apps

EOF

# --- Finish ---
echo "==> Installation complete. Reboot into your new Arch Batocera-style console!"
echo "Post-installation: Run the step-by-step configuration guide for controller tweaks, ROM setup, RGSX Downloader usage, trigger mouse clicks, and theme fine-tuning."
