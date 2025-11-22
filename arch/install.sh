#!/bin/bash
set -euo pipefail
trap 'echo "Error on line $LINENO: $BASH_COMMAND"' ERR

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"

cecho() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

cecho "$YELLOW" "Synchronizing system time..."
timedatectl set-ntp true
cecho "$GREEN" "Time synched!"

cecho "$YELLOW" "Current system time:"
timedatectl status

cecho "$YELLOW" "Detecting available disks..."
lsblk -dpno NAME,SIZE,MODEL | grep -v "loop"

if ! lsblk -dn | grep -q .; then
    cecho "$RED" "No disks found. Cannot continue."
    exit 1
fi

while true; do
    cecho "$BLUE" "Please select a disk to install arch on (e.g., /dev/sda):"
    read -r DISK

    if [ ! -b "$DISK" ]; then
        cecho "$RED" "Disk $DISK does not exist. Select again."
        continue
    fi

    cecho "$RED" "WARNING: All data on $DISK will be erased."
    cecho "$BLUE" "Are you sure you want to continue? (yes/no):"
    read -r CONFIRM

    if [[ "$CONFIRM" == yes ]]; then
        cecho "$GREEN" "Disk $DISK selected. Proceeding..."
        break;
    else
        cecho "$YELLOW" "Let's try that again!"
    fi
done

if [ -d /sys/firmware/efi ]; then
    BOOT_TYPE="uefi"
else
    BOOT_TYPE="bios"
fi

cecho "$YELLOW" "Erasing $DISK..."
sgdisk -Z "$DISK"

mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
HALF="${mem_gb}G"

cecho "$BLUE" "Enter swap size, appended with M or G (RAM size if using hibernation, half or RAM size without, or press enter for recommended $HALF):"
read -r SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-$HALF}

if [[ "$BOOT_TYPE" == "uefi" ]]; then
    cecho "$YELLOW" "Creating EFI partition (512M)..."
    sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
else
    cecho "$YELLOW" "Create BOOT partition (1M)..."
    sgdisk -n 1:0:+1M -t 1:ef02 "$DISK"
fi

cecho "$YELLOW" "Creating Swap partition ($SWAP_SIZE)..."
sgdisk -n 2:0:+$SWAP_SIZE -t 2:8200 "$DISK"

cecho "$YELLOW" "Creating root partition (rest of disk)..."
sgdisk -n 3:0:0 -t 3:8300 "$DISK"

cecho "$GREEN" "Partitions created!"

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

if [[ "$BOOT_TYPE" == "uefi" ]]; then
    cecho "$YELLOW" "Formatting EFI partition as FAT32..."
    mkfs.fat -F32 "$EFI_PART"
fi

cecho "$YELLOW" "Setting up Swap partition..."
mkswap "$SWAP_PART"
swapon "$SWAP_PART"

cecho "$YELLOW" "Formatting root partition as ext4..."
mkfs.ext4 "$ROOT_PART"

cecho "$YELLOW" "Mounting partitions..."
mount "$ROOT_PART" /mnt

if [[ "$BOOT_TYPE" == "uefi" ]]; then
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
fi

cecho "$GREEN" "Disk formatted and mounted!"

valid_countries=$(reflector --list-countries | awk '{print $1}')
while true; do
    cecho "$BLUE" "Enter your country code (e.g., US, DE, FR):"
    read -r MIRROR_COUNTRY
    
    if ! echo "$valid_countries" | grep -iq "^$MIRROR_COUNTRY$"; then
        cecho "$RED" "Invalid country code: $MIRROR_COUNTRY"
        cecho "$YELLOW" "Did you mean one of these?"

        echo "$valid_countries" | grep -i "$MIRROR_COUNTRY"
    else
        break
    fi
done

cecho "$YELLOW" "Updating mirrorlist for $MIRROR_COUNTRY..."
reflector --country "$MIRROR_COUNTRY" --protocol https --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

cecho "$YELLOW" "Installing base system..."
pacstrap /mnt --noconfirm base linux linux-firmware

cecho "$YELLOW" "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

cecho "$GREEN" "Installed basic system and generated fstab!"

cecho "$YELLOW" "Chrooting into the new system for configuration..."

while true; do
    cecho "$BLUE" "Enter your timezone (e.g., Europe/Berlin):"
    read -r TIMEZONE

    if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        cecho "$RED" "Invalid timezone: $TIMEZONE"
        cecho "$YELLOW" "Did you mean one of these?"

        find /usr/share/zoneinfo -type f | sed 's|/usr/share/zoneinfo/||' | grep -i "$TIMEZONE" | head -n 10
    else
        break;
    fi
done
arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
arch-chroot /mnt hwclock --systohc

cecho "$GREEN" "Timezone set!"

cecho "$BLUE" "Enter your locale (e.g., en_US.UTF-8):"
read -r LOCALE
echo "$LOCALE UTF-8" >> /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf

cecho "$GREEN" "Locale set to $LOCALE!"

cecho "$BLUE" "Enter hostname for your system:"
read -r NAME
echo "$NAME" > /mnt/etc/hostname

cecho "$GREEN" "Set hostname to $NAME"

cecho "$BLUE" "Set root password (wait for password prompt):"
arch-chroot /mnt passwd

cecho "$BLUE" "Enter username:"
read -r USERNAME
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
cecho "$BLUE" "Set password for $USERNAME (wait for password prompt):"
arch-chroot /mnt passwd "$USERNAME"

cecho "$BLUE" "Should this user have sudo/root privileges? (recommended) (y/n):"
read -r SUDO_CHOICE

if [[ "$SUDO_CHOICE" == "y" ]]; then
    pacstrap /mnt --noconfirm sudo
    arch-chroot /mnt usermod -aG wheel "$USERNAME"
    arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    cecho "$GREEN" "User $USERNAME added to sudoers!"
else
    cecho "$YELLOW" "User $USERNAME will not have sudo privileges..."
fi

if [[ "$BOOT_TYPE" == "uefi" ]]; then
    cecho "$YELLOW" "Installing GRUB for EUFI..."
    pacstrap /mnt --noconfirm grub efibootmgr
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    cecho "$GREEN" "Installed GRUB!"
else
    cecho "$YELLOW" "Installing GRUB for BIOS/legacy..."
    pacstrap /mnt --noconfirm grub
    arch-chroot /mnt grub-install --target=i386-pc "$DISK"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    cecho "$GREEN" "Installed GRUB!"
fi

cecho "$BLUE" "Arch Linux is successfully installed. You can either reboot now into a fresh TTY and install everything yourself, or you can continue installing my own sway preset. Do you want to install my sway setup? (y/n)"
read -r INSTALL_SWAY

if [[ "$INSTALL_SWAY" == "n" ]]; then
    cecho "$YELLOW" "Cleaning up..."
    umount -R /mnt
    swapoff "$SWAP_PART"
    cecho "$GREEN" "System installed!"

    cecho "$YELLOW" "Press enter to reboot..."
    read -r
    reboot
fi

cecho "$YELLOW" "Installing dependencies..."
arch-chroot /mnt pacman -Syyu --noconfirm \
    lightdm lightdm-gtk-greeter \
    sway sway-session swaylock waybar wofi grim slurp wl-clipboard \
    nvim ghostty vivaldi ttf-jetbrains-mono-nerd \
    pipewire pipewire-pulse pipewire-alsa pavucontrol wireplumber \
    dolphin unzip

cecho "$YELLOW" "Enabling services..."
arch-chroot /mnt /bin/bash -c "systemctl enable lightdm.service"

cecho "$GREEN" "Sway and all apps installed!"

cecho "$YELLOW" "Cleaning up..."
umount -R /mnt
swapoff "$SWAP_PART"
cecho "$GREEN" "System installed!"

cecho "$YELLOW" "Press enter to reboot..."
read -r
reboot
