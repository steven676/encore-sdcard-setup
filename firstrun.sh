#!/sbin/sh

# first-run partitioner masquerading as update binary
#
# arguments: update-binary [recovery-API-version] [command-fd] [update-zip]
#
# As of API version 2, command-fd is a file descriptor to which we can write
# commands to be interpreted by the recovery.

# Copyright (C) 2014 Steven Luo
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

# Ensure we're being used with a supported recovery API version
recoveryapi="$1"
[ "$recoveryapi" ] || exit 1
[ "$recoveryapi" -eq 2 ] || [ "$recoveryapi" -eq 3 ] || exit 1

ui_print() {
	echo "ui_print $1" >&$cmdfd
	echo "ui_print" >&$cmdfd
}

# autofill a segment of the progress bar over the next N seconds
# arguments: autofill_progress [segment-fraction] [seconds]
autofill_progress() {
	echo "progress $1 $2" >&$cmdfd
}

# define the size of the next segment of the progress bar to be filled with
# set_progress
progress_segment() {
	echo "progress $1 0" >&$cmdfd
}

# set progress within the defined progress segment
set_progress() {
	echo "set_progress $1" >&$cmdfd
}

# clean up
do_cleanup() {
	curdir="`pwd`"
	cd /tmp
	rm -f $UNPACK_FILES
	cd $curdir
	rm -f /tmp/sdcard-first-run.zip
}

# report a failure to the user
fail() {
	message="$1"
	[ "$message" ] || message="Failed!"
	ui_print "$message"
	do_cleanup
	exit 3
}

cmdfd="$2"
updatezip="$3"

BLKDEV=/dev/block/mmcblk1
DATA_SECTOR_OFFSET=2097152

UNPACK_FILES="align.sh mkfs.fat"

ui_print "Performing first-run setup..."

# Unpack needed files
rm -f $UNPACK_FILES
unzip "$updatezip" $UNPACK_FILES -d /tmp || fail "Couldn't get files from update package $updatezip !"

. /tmp/align.sh

# Get SD card size in sectors
cardsize="`fdisk -ul "$BLKDEV" | grep 'total .* sectors' | sed -e 's/^.* total \(.*\) sectors$/\1/'`"
if [ -z "$cardsize" ] || [ "$cardsize" -le 0 ]; then
	fail "Couldn't get valid SD card size!"
fi

# Choose partition sizes based on the SD card size
if [ "$cardsize" -lt 7500000 ]; then
	ui_print "This SD card is too small to support an Android installation."
	ui_print "Use an SD card that's 4 GB or bigger."
	fail
elif [ "$cardsize" -le 16777216 ]; then
	# 4-8 GB: /data 2 GB, remainder /sdcard
	data_sectors=4194304
	sdcard_sectors=0
elif [ "$cardsize" -le 77594624 ]; then
	# 8 GB < size < 37 GB: /data 4 GB, remainder /sdcard
	data_sectors=8388608
	sdcard_sectors=0
else
	# size > 37 GB: 32 GB /sdcard, remainder /data
	data_sectors=0
	sdcard_sectors=67108864
fi

# Partition the SD card
ui_print "Partitioning the SD card..."
progress_segment 0.1

if [ $data_sectors -gt 0 ]; then
	fixed_part_num=3
	fixed_part_sectors=$data_sectors
else
	fixed_part_num=4
	fixed_part_sectors=$sdcard_sectors
fi

umount /boot
fdisk -u "$BLKDEV" <<EOF
c
n
p
$fixed_part_num
$DATA_SECTOR_OFFSET
+$(($fixed_part_sectors - 1))
n
p
$((DATA_SECTOR_OFFSET + $fixed_part_sectors))

t
4
0c
w
EOF
[ $? -eq 0 ] || fail "Partitioning the SD card failed!"

set_progress 1.0

# Format the partitions
ui_print "Formatting /data for the first time..."

if [ $data_sectors -eq 0 ]; then
	data_sectors="`fdisk -ul "$BLKDEV" | grep ^"$BLKDEV"p3 | awk '{ print $3 - $2 + 1}'`"
fi
if [ -z "$data_sectors" ] || [ $data_sectors -eq 0 ]; then
	fail "Couldn't get /data partition size!"
fi

# Very rough estimate of how long it takes to format: 5 seconds/GB
# Based on stopwatch-timing the formatting of a 2 GB /data partition on a
# SanDisk class 4 SD card on the Nook Color
segment_time=$(div_round_up $((5 * $data_sectors)) 2097152)
autofill_progress 0.2 $segment_time

# XXX: use mke2fs for better control over layout?
#make_ext4fs -a data "$BLKDEV"p3

# Select a journal size similar to what Android's make_ext4fs would choose
# Android wants 1/64 of the blocks as the journal, up to a max of 128 MB; here,
# we only control the journal size to the nearest MB
data_journal_size=$(div_round_up $(($data_sectors * 8)) 1048576)
[ $data_journal_size -lt 4 ] && data_journal_size=4
[ $data_journal_size -gt 128 ] && data_journal_size=128

mke2fs -t ext4 -b 4096 -I 256 -J size=$data_journal_size -m 0 -E stride=1024,stripe-width=1024 "$BLKDEV"p3 || fail "Formatting /data failed!"
tune2fs -c 0 -i 0 -e remount-ro "$BLKDEV"p3

set_progress 1.0

ui_print "Formatting /sdcard for the first time..."

if [ $sdcard_sectors -eq 0 ]; then
	sdcard_sectors="`fdisk -ul "$BLKDEV" | grep ^"$BLKDEV"p4 | awk '{ print $3 - $2 + 1}'`"
fi
if [ -z "$sdcard_sectors" ] || [ $sdcard_sectors -eq 0 ]; then
	fail "Couldn't get /sdcard partition size!"
fi

# Very rough estimate of how long it takes to format: 0.5 seconds/GB
# Based on stopwatch-timing the formatting of a 4.5 GB /sdcard partition on a
# SanDisk class 4 SD card on the Nook Color
segment_time=$(div_round_up $sdcard_sectors 4194304)
autofill_progress 0.2 $segment_time

# Ensure alignment of the FAT data section to an eraseblock boundary
# Assume the largest common eraseblock size, which ensures alignment on smaller
# eraseblock boundaries as well
ERASEBLOCK_SIZE=4194304
cluster_size="`select_cluster_size $sdcard_sectors $ERASEBLOCK_SIZE`"
reserved_sectors="`align_reserved_sectors $sdcard_sectors $ERASEBLOCK_SIZE $cluster_size`"

chmod 0755 /tmp/mkfs.fat
/tmp/mkfs.fat -F 32 -s $(($cluster_size/512)) -h 0 -R $reserved_sectors -a "$BLKDEV"p4 || fail "Formatting /sdcard failed!"

set_progress 1.0

# Install Google apps, if a package is present
ui_print "Installing Google apps..."
mount /boot
gapps_zips="`echo /boot/gapps*.zip`"
if [ x"$gapps_zips" != x"/boot/gapps*.zip" ]; then
	# Install the Google apps
	for zip in $gapps_zips; do
		mkdir -p /tmp/gapps
		unzip "$zip" META-INF/com/google/android/update-binary -d /tmp/gapps
		chmod 0755 /tmp/gapps/META-INF/com/google/android/update-binary
		/tmp/gapps/META-INF/com/google/android/update-binary "$recoveryapi" "$cmdfd" "$zip"
		result=$?
		if [ $result -ne 0 ]; then
			fail "Google apps installation failed: status $result"
		fi
		rm -rf /tmp/gapps
		rm -f "$zip"
		# Only install one Google apps package!
		break
	done
else
	ui_print "No Google apps found -- skipping."
	progress_segment 0.4
	set_progress 1.0
fi

# Make sure the recovery doesn't boot next time
ui_print "Configuring system boot..."
progress_segment 0.05
mv /boot/uImage.real /boot/uImage
mv /boot/uRamdisk.real /boot/uRamdisk
rm -f /boot/recovery-commands /boot/postrecoveryboot.sh /boot/sdcard-first-run.zip
umount /boot
set_progress 1.0

ui_print "Cleaning up..."
progress_segment 0.05
do_cleanup
set_progress 1.0

ui_print "Done!"

exit 0
