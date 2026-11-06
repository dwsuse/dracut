#!/bin/sh
#
# Record in the nvme-cli ownership registry (/run/nvme/registry, nvme-cli 3)
# which NVMe-oF controllers the booted system depends on.
#
# The controllers behind the file systems mounted under $NEWROOT get
# owner=pre-os: they were set up before the OS took over, and tools in the
# real root (nvme disconnect-all, nvme-discoverd, ...) must leave them alone.
#
# Every other controller connected in the initrd is left, or made, unowned
# ("orphaned"), so the OS can adopt or drop it. Only NBFT connections
# (owner=nbft, written by "nvme connect-all --nbft") have an owner to drop;
# the other initrd connections are unowned already.
#
# /run moves into the real root at switch_root, so the entries survive it.

command -v info > /dev/null || . /lib/dracut-lib.sh

NVMF_REGISTRY=/run/nvme/registry
NVMF_PRE_OS_OWNER=pre-os

# nvme-cli 2 has no registry
nvme registry --help > /dev/null 2>&1 || return 0

# Space separated list of the controllers behind the mounts
nvmf_pre_os=

nvmf_pre_os_add() {
    case " $nvmf_pre_os " in
        *" $1 "*) ;;
        *) nvmf_pre_os="${nvmf_pre_os:+$nvmf_pre_os }$1" ;;
    esac
}

# Add the NVMe-oF controllers behind the block device at sysfs path $1,
# following partitions and stacked devices (dm, md).
nvmf_pre_os_add_blockdev() {
    local p="$1" s dev c trtype

    [ -e "$p/partition" ] && p=${p%/*}
    for s in "$p"/slaves/*; do
        [ -e "$s" ] || continue
        nvmf_pre_os_add_blockdev "$(readlink -f "$s")"
    done
    case ${p##*/} in
        nvme*) ;;
        *) return 0 ;;
    esac
    dev=$(readlink -f "$p/device") || return 0
    if [ -f "$dev/transport" ]; then
        # no native multipath: the parent is the controller
        set -- "$dev"
    else
        # native multipath: the parent is the subsystem, which links all
        # path controllers
        set -- "$dev"/nvme[0-9]*
    fi
    for c in "$@"; do
        [ -f "$c/transport" ] || continue
        read -r trtype < "$c/transport"
        case $trtype in
            tcp | rdma | fc) nvmf_pre_os_add "${c##*/}" ;;
        esac
    done
}

# Collect the controllers behind the mounts under $NEWROOT. The third field
# of mountinfo is the device, the fifth the mount point.
nvmf_pre_os_collect() {
    local _id _parent majmin _root mnt _rest

    while read -r _id _parent majmin _root mnt _rest; do
        case $mnt in
            "$NEWROOT" | "$NEWROOT"/*) ;;
            *) continue ;;
        esac
        # 0:N is an anonymous device (btrfs, overlay, tmpfs, ...)
        case $majmin in
            0:*) continue ;;
        esac
        [ -e "/sys/dev/block/$majmin" ] || continue
        nvmf_pre_os_add_blockdev "$(readlink -f "/sys/dev/block/$majmin")"
    done < /proc/self/mountinfo
}

nvmf_registry_owner() {
    local owner=
    [ -f "$NVMF_REGISTRY/$1/owner" ] \
        && read -r owner < "$NVMF_REGISTRY/$1/owner"
    echo "$owner"
}

nvmf_pre_os_collect

for _c in $nvmf_pre_os; do
    _owner=$(nvmf_registry_owner "$_c")
    case $_owner in
        "$NVMF_PRE_OS_OWNER") ;;
        "" | nbft)
            if nvme registry update "$_c" --attr=owner \
                --value="$NVMF_PRE_OS_OWNER" < /dev/null; then
                info "nvmf: $_c: owner ${_owner:-(none)} -> $NVMF_PRE_OS_OWNER"
            else
                warn "nvmf: $_c: could not set owner $NVMF_PRE_OS_OWNER"
            fi
            ;;
        *)
            info "nvmf: $_c: owned by $_owner, not changing it"
            ;;
    esac
done

for _e in "$NVMF_REGISTRY"/nvme*; do
    [ -d "$_e" ] || continue
    _c=${_e##*/}
    case " $nvmf_pre_os " in
        *" $_c "*) continue ;;
    esac
    [ "$(nvmf_registry_owner "$_c")" = nbft ] || continue
    if nvme registry delete "$_c" --attr=owner < /dev/null; then
        info "nvmf: $_c: owner nbft dropped, not needed for the root"
    else
        warn "nvmf: $_c: could not drop owner nbft"
    fi
done

unset nvmf_pre_os _c _e _owner
