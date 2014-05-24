#!/bin/sh

# Library routines for aligning FAT data area with SD card structure
#
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

# FAT filesystem parameters which are fixed for purposes of this script
NUM_FATS=2
MIN_RESERVED_SECTORS=12

# The minimum size of a FAT32 data area is 65525 clusters, but Windows 2000/XP
# require at least 65527 clusters, and mkdosfs doesn't like to create FAT32
# filesystems with fewer than 65529 clusters (dosfsck has no issue with smaller
# filesystems, though).
FAT32_MIN_CLUSTERS=65529

# Integer division: $1/$2 with fractions always rounded up
div_round_up() {
        echo $((($1 + $2 - 1)/$2))
}

# Compute a value for a FAT32 filesystem's reserved sector count which results
# in the start of the data area aligning with an eraseblock boundary.
#
# A FAT32 filesystem is structured as follows:
#
#     [ reserved sectors ][ FAT #1 ][ additional FATs ][ data area ]
#
# The first sector (part of the reserved range) is typically a boot sector,
# whereas the second sector is a filesystem information block for FAT32.
# Additional reserved sectors can be required by the boot sector code;
# Windows usually reserves at least 12 sectors at the beginning of the
# filesystem for this.  Typically, two copies of the FAT are stored
# back-to-back, though a different number is at least theoretically possible.
#
# As with other filesystems, ensuring the start of the data area is aligned to
# an eraseblock boundary is important for performance; unfortunately, mkdosfs
# is not able to do this for us (the best it can do is align structures to
# clusters, which are considerably smaller than flash eraseblocks are on recent
# media).  Good flash vendors do this with their factory-formatted media (look
# at any factory-fresh SanDisk SD card with dosfsck -v, for example).
#
# Aligning the start of the data area essentially means ensuring that the FATs
# plus the reserved sectors extend over the whole of one or more eraseblocks.
# We can have an arbitrary number of reserved sectors, so the obvious strategy
# is to determine the size of the FATs and then use reserved sectors to pad
# to the nearest eraseblock boundary.  However, FAT size is determined by the
# size of the data area:
#
#     FAT32 size = 4 bytes * (number of data clusters + 2)
#
# (clusters are groups of 2^N sectors which form the basic allocation unit of
# the filesystem).
#
# How, then, to compute the needed number or reserved sectors?  We first note
# that, according to the above formula, each data cluster requires four bytes
# in FAT space.  Treating the minimum of 12 reserved sectors and the 8 bytes at
# the beginning of each FAT as overhead, we come to the following way of
# dividing up our volume:
#
#     [12 reserved sectors][8 bytes FAT#1][8 bytes FAT#2][chunk][chunk][...]
#
# where each "chunk" consists of one cluster plus the space needed to track it
# in the FATs:
# 
#     [cluster][4 bytes in FAT#1][4 bytes in FAT#2]
#
# Computing the number of these chunks that fit in our volume will give us the
# largest possible data area, and therefore the largest possible FAT, that can
# be used on this filesystem.  We then find the smallest number of eraseblocks
# that will fit two copies of the maximal FAT and the minimum number of reserved
# sectors, and offset the start of the data area by that amount.  This gives
# us the final data area size, from which we can compute the actual size of the
# FATs (guaranteed to be no larger than the maximal FAT) and the appropriate
# number of reserved sectors to take up the remainder of the eraseblocks
# set aside for reserved sectors and FATs.
#
# The actual computations below follow the process described above, though
# they're complicated by the need in many places to round to the nearest whole
# unit when dividing.
#
# When cluster alignment is enabled, the alignment algorithm also assures that
# the FAT size and reserved sector count are a multiple of the cluster size by
# rounding up to the nearest cluster boundary in the appropriate places.

align_reserved_sectors() {
	sdcard_sectors="$1"
	shift
	ERASEBLOCK_SIZE="$1"
	shift
	CLUSTER_SIZE="$1"
	shift
	if [ x"$1" = x"cluster_align" ]; then
		cluster_align=1
		shift
	fi

	SECTORS_PER_CLUSTER=$(($CLUSTER_SIZE/512))
	SECTORS_PER_ERASEBLOCK=$(($ERASEBLOCK_SIZE/512))
	CLUSTERS_PER_ERASEBLOCK=$(($ERASEBLOCK_SIZE/$CLUSTER_SIZE))

	# Once aligned, the data area will consist of some number of clusters
	# starting at a multiple of the eraseblock size (which is divisible by
	# the cluster size).  If the filesystem size isn't an integer multiple
	# of the cluster size, the leftover area at the end is unusable and
	# should not factor into our calculations.  Therefore, we represent
	# the filesystem size in whole clusters throughout, ignoring leftover
	# sectors if they exist.
	sdcard_clusters=$(($sdcard_sectors/$SECTORS_PER_CLUSTER))

	# Start reserved_sectors at the minimum
	reserved_sectors=$MIN_RESERVED_SECTORS
	if [ "$cluster_align" ]; then
		# Reserved sectors needs to be a multiple of the cluster size.
		# However, so does the FAT size, and this imposes the added
		# restriction that reserved sectors must be an *even* multiple
		# of the cluster size.
		#
		# Why?  Let f be the FAT size, r the reserved area size, and e
		# the eraseblock size (all expressed in clusters); then we have
		#    2f + r = eN
		# where N is some integer.  But since eraseblock size is always
		# a power of two, as is cluster size, e must be even; therefore,
		# r must be even as well if this equation is to hold.
		reserved_sectors=$(( $(div_round_up $reserved_sectors $((2*$SECTORS_PER_CLUSTER))) * (2*$SECTORS_PER_CLUSTER) ))
	fi

	# Calculate the maximal FAT size in bytes (rounded up to the nearest
	# whole chunk), then round the size up to the nearest whole sector
	fat_size_bytes=$((4*$(div_round_up $((($sdcard_clusters*$SECTORS_PER_CLUSTER - $reserved_sectors)*512 - 8*$NUM_FATS)) $(($CLUSTER_SIZE + $NUM_FATS*4))) + 8))
	fat_sectors=$(div_round_up $fat_size_bytes 512)
	if [ "$cluster_align" ]; then
		# FAT size needs to be a multiple of the cluster size
		fat_sectors=$(( $(div_round_up $fat_sectors $SECTORS_PER_CLUSTER) * $SECTORS_PER_CLUSTER ))
	fi

	# Compute the number of eraseblocks needed to hold the two FATs plus
	# required reserve sectors
	fat_data_offset_ebs=$(div_round_up $(($NUM_FATS*$fat_sectors + $reserved_sectors)) $SECTORS_PER_ERASEBLOCK)

	# Calculate the actual FAT size assuming that we set aside whole
	# eraseblocks to hold reserved sectors and FATs
	fat_size_bytes=$((($sdcard_clusters - $fat_data_offset_ebs*$CLUSTERS_PER_ERASEBLOCK)*4 + 8))
	fat_sectors=$(div_round_up $fat_size_bytes 512)
	if [ "$cluster_align" ]; then
		fat_sectors=$(( $(div_round_up $fat_sectors $SECTORS_PER_CLUSTER) * $SECTORS_PER_CLUSTER ))
	fi

	# Compute the final number of reserved sectors needed to pad out the
	# FATs to eraseblock size
	reserved_sectors=$(($fat_data_offset_ebs*$SECTORS_PER_ERASEBLOCK - $NUM_FATS * $fat_sectors))

	if [ x"$1" = x"test" ]; then
		# For use by the test suite
		echo "$reserved_sectors $fat_data_offset_ebs $fat_size_bytes $fat_sectors"
	else
		echo $reserved_sectors
	fi
}

# Select the largest possible cluster size for a given FAT32 filesystem size.
#
# The smallest FAT32 data area we're willing to create is 65529 clusters; for a
# data area this size, the FAT will be 512 sectors.  Adding the minimum
# reserved sectors gives the minimum allowed FS size for the selected cluster
# size.
select_cluster_size() {
	sdcard_sectors="$1"
	shift
	eraseblock_size="$1"
	shift
	if [ x"$1" = x"cluster_align" ]; then
		cluster_align=1
		shift
	fi

	sectors_per_eraseblock=$(($eraseblock_size / 512))

	# Start at the maximum "normal" cluster size of 32 KB
	cluster_size=32768

	while [ $cluster_size -ge 512 ]; do
		sectors_per_cluster=$(($cluster_size / 512))

		reserved_sectors=$MIN_RESERVED_SECTORS
		[ "$cluster_align" ] && reserved_sectors=$(( $(div_round_up $reserved_sectors $sectors_per_cluster) * $sectors_per_cluster ))
		data_offset_ebs=$(div_round_up $(($reserved_sectors + $NUM_FATS*512)) $sectors_per_eraseblock)

		minimum_fs_size=$(($FAT32_MIN_CLUSTERS*$sectors_per_cluster + $data_offset_ebs*$sectors_per_eraseblock))
		[ $sdcard_sectors -ge $minimum_fs_size ] && break

		cluster_size=$(($cluster_size / 2))
	done

	echo $cluster_size
}
