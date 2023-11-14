#!/usr/bin/env bash

set -o pipefail

declare -r workdir='/mnt'
declare -r osidir='/etc/os-installer'
declare -r rootlabel='arkane_root'

## Generic checks
#
# Ensure user is in sudo group
for group in $(groups); do

	if [[ $group == 'wheel' || $group == 'sudo' ]]; then
		declare -ri sudo_ok=1
	fi

done

# If user is not in sudo group notify and exit with error
if [[ ! -n $sudo_ok ]]; then
	printf 'The current user is not a member of either the sudo or wheel group, this os-installer configuration requires sudo permissions\n'
	exit 1
fi

# Function used to quit and notify user or error
quit_on_err () {
	if [[ -v $1 ]]; then
		printf '$1\n'
	fi

	# Ensure the terminal has time to print before exiting
	sleep 2

	exit 1
}

# sanity check that all variables were set
if [ -z ${OSI_LOCALE+x} ] || \
   [ -z ${OSI_DEVICE_PATH+x} ] || \
   [ -z ${OSI_DEVICE_IS_PARTITION+x} ] || \
   [ -z ${OSI_DEVICE_EFI_PARTITION+x} ] || \
   [ -z ${OSI_USE_ENCRYPTION+x} ] || \
   [ -z ${OSI_ENCRYPTION_PIN+x} ]
then
    printf 'install.sh called without all environment variables set!\n'
    exit 1
fi

# Check if something is already mounted to $workdir
mountpoint -q $workdir && quit_on_err "$workdir is already a mountpoint, unmount this directory and try again"

# Write partition table to the disk unless manual partitioning is used
if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then
	sudo sfdisk $OSI_DEVICE_PATH < $osidir/bits/part.sfdisk || quit_on_err 'Failed to write partition table to disk'
fi

# NVMe drives follow a slightly different naming scheme to other block devices
# this will change `/dev/nvme0n1` to `/dev/nvme0n1p` for easier parsing later
if [[ $OSI_DEVICE_PATH == *"nvme"*"n"* ]]; then
	declare -r partition_path="${OSI_DEVICE_PATH}p"
else
	declare -r partition_path="${OSI_DEVICE_PATH}"
fi

# Check if encryption is requested, write filesystems accordingly
if [[ $OSI_USE_ENCRYPTION -eq 1 ]]; then

	# If user requested disk encryption
	if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then
		# If target is a drive
		sudo mkfs.fat -F32 ${partition_path}1 || quit_on_err "Failed to create FAT filesystem on ${partition_path}1"
		echo $OSI_ENCRYPTION_PIN | sudo cryptsetup -q luksFormat ${partition_path}2 || quit_on_err "Failed to create LUKS partition on ${partition_path}2"
		echo $OSI_ENCRYPTION_PIN | sudo cryptsetup open ${partition_path}2 $rootlabel - || quit_on_err 'Failed to unlock LUKS partition'
		sudo mkfs.btrfs -f -L $rootlabel /dev/mapper/$rootlabel || quit_on_err 'Failed to create Btrfs partition on LUKS'

		sudo mount -o compress=zstd /dev/mapper/$rootlabel $workdir || quit_on_err "Failed to mount LUKS/Btrfs root partition to $workdir"
		sudo mount --mkdir ${partition_path}1 $workdir/boot || quit_on_err 'Failed to mount boot'
		sudo btrfs subvolume create $workdir/home || quit_on_err 'Failed to create home subvolume'
	else
		# If target is a partition
		sudo mkfs.fat -F32 $OSI_DEVICE_EFI_PARTITION || quit_on_err "Failed to create FAT filesystem on $OSI_DEVICE_EFI_PARTITION"
		echo $OSI_ENCRYPTION_PIN | sudo cryptsetup -q luksFormat $OSI_DEVICE_PATH || quit_on_err "Failed to create LUKS partition on $OSI_DEVICE_PATH"
		echo $OSI_ENCRYPTION_PIN | sudo cryptsetup open $OSI_DEVICE_PATH $rootlabel - || quit_on_err 'Failed to unlock LUKS partition'
		sudo mkfs.btrfs -f -L $rootlabel /dev/mapper/$rootlabel || quit_on_err 'Failed to create Btrfs partition on LUKS'

		sudo mount -o compress=zstd /dev/mapper/$rootlabel $workdir || quit_on_err "Failed to mount LUKS/Btrfs root partition to $workdir"
		sudo mount --mkdir $OSI_DEVICE_EFI_PARTITION $workdir/boot || quit_on_err 'Failed to mount boot'
		sudo btrfs subvolume create $workdir/home || quit_on_err 'Failed to create home subvolume'
	fi

else

	# If no disk encryption requested
	if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then
		# If target is a drive
		sudo mkfs.fat -F32 ${partition_path}1 || quit_on_err "Failed to create FAT filesystem on ${partition_path}1"
		sudo mkfs.btrfs -f -L $rootlabel ${partition_path}2 || quit_on_err "Failed to create root on ${partition_path}2"
		sudo mount -o compress=zstd ${partition_path}2 $workdir || quit_on_err "Failed to mount root to $workdir"
		sudo mount --mkdir ${partition_path}1 $workdir/boot || quit_on_err 'Failed to mount boot'
	else
		# If target is a partition
		sudo mkfs.fat -F32 $OSI_DEVICE_EFIT_PARTITION || quit_on_err "Failed to create FAT filesystem on $OSI_EFI_PARTITION"
		sudo mkfs.btrfs -f -L $rootlabel $OSI_DEVICE_PATH || quit_on_err "Failed to create root on $OSI_DEVICE_PATH"
		sudo mount -o compress=zstd $OSI_DEVICE_PATH $workdir || quit_on_err "Failed to mount root to $workdir"
		sudo mount --mkdir $OSI_DEVICE_EFIT_PARTITION $workdir/boot || quit_on_err 'Failed to mount boot'
	fi

	sudo btrfs subvolume create $workdir/home || quit_on_err 'Failed to create home subvoume'
fi

# Ensure partitions are mounted, quit and error if not
for mountpoint in $workdir $workdir/boot; do
	mountpoint -q $mountpoint || quit_on_err "No volume mounted to $mountpoint"
done

# Grab package lists
readarray base_packages < $osidir/bits/base.list || quit_on_err 'Failed to read base.list'
readarray arkdep_fallback_packages < $osidir/bits/arkdep.list || quit_on_err 'Failed to read arkdep.list'

# Install the core fallback system
# Retry installing three times before quitting
for n in {1..3}; do
	sudo pacstrap $workdir ${base_packages[*]}
	exit_code=$?

	if [[ $exit_code == 0 ]]; then
		break
	else
		if [[ $n == 3 ]]; then
			quit_on_err 'Failed pacstrap after 3 retries'
		fi
	fi
done

# Copy the ISO's pacman.conf file to the new installation
sudo cp -v /etc/pacman.conf $workdir/etc/pacman.conf || quit_on_err 'Failed to copy local pacman.conf to new root'

# For some reason Arch does not populate the keyring upon installing
# arkane-keyring, thus we have to populate it manually
sudo arch-chroot $workdir pacman-key --populate arkane || quit_on_err 'Failed to populate pacman keyring with Arkane keys'

# Install the remaining packages in fallback system
# Retry installing three times before quitting
for n in {1..3}; do
	sudo arch-chroot $workdir pacman -S --noconfirm ${arkane_fallback_packages[*]}
	exit_code=$?

	if [[ $exit_code == 0 ]]; then
		break
	else
		if [[ $n == 3 ]]; then
			quit_on_err 'Failed pacman after 3 retries'
		fi
	fi
done


# Install the systemd-boot bootloader
sudo arch-chroot $workdir bootctl install || quit_on_err 'Failed to install systemd-boot'

# Initialize arkdep
sudo arch-chroot $workdir arkdep init || quit_on_err 'Failed to init arkep'

exit 0
