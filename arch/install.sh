#!/bin/bash
set -euo pipefail

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

while true; do
    cecho "$BLUE" "Please select a disk to install arch on (e.g., /dev/sda):"
    read -r DISK

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

cecho "$BLUE" "Enter swap size, appended with M or G (RAM size if using hibernation, half or RAM size without):"
read -r SWAP_SIZE

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

cecho "$BLUE" "Enter your country code (e.g., US, DE, FR):"
read -r MIRROR_COUNTRY

cecho "$YELLOW" "Updating mirrorlist for $MIRROR_COUNTRY..."
reflector --country "$MIRROR_COUNTRY" --sort rate --save /etc/pacman.d/mirrorlist

cecho "$YELLOW" "Installing base system..."
pacstrap /mnt base linux linux-firmware

cecho "$YELLOW" "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

cecho "$GREEN" "Installed basic system and generated fstab!"

cecho "$YELLOW" "Chrooting into the new system for configuration..."

cecho "$BLUE" "Enter your timezone (e.g., Europe/Berlin):"
read -r TIMEZONE
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

cecho "$BLUE" "Set root password:"
arch-chroot /mnt passwd

cecho "$BLUE" "Enter username:"
read -r USERNAME
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
cecho "$BLUE" "Set password for $USERNAME:"
arch-chroot /mnt passwd "$USERNAME"

cecho "$BLUE" "Should this user have sudo/root privileges? (y/n):"
read -r SUDO_CHOICE

if [[ "$SUDO_CHOICE" == "y" ]]; then
    arch-chroot /mnt pacman -Sy --noconfirm sudo
    arch-chroot /mnt usermod -aG wheel "$USERNAME"
    arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    cecho "$GREEN" "User $USERNAME added to sudoers!"
else
    cecho "$YELLOW" "User $USERNAME will not have sudo privileges..."
fi

if [[ "$BOOT_TYPE" == "uefi" ]]; then
    cecho "$YELLOW" "Installing GRUB for EUFI..."
    arch-chroot /mnt pacman -Sy --noconfirm grub efibootmgr
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    cecho "$GREEN" "Installed GRUB!"
else
    cecho "$YELLOW" "Installing GRUB for BIOS/legacy..."
    arch-chroot /mnt pacman -Sy --noconfirm grub
    arch-chroot /mnt grub-install --target=i386-pc "$DISK"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    cecho "$GREEN" "Installed GRUB!"
fi

cecho "$YELLOW" "Cleaning up..."
umount -R /mnt
swapoff "$SWAP_PART"
cecho "$GREEN" "System installed! Press enter to reboot."
read -r
reboot
