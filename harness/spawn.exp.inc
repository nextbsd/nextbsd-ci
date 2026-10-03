# spawn.exp.inc — the expect skeleton: spawn the guest exactly as qemu-arch.sh
# describes it (binary, machine, firmware, accel, NIC, video) with a serial
# console on stdio, a log file, and -no-reboot so a clean halt exits.
#
# Env (set by harness/boot-test.sh; the per-arch shape by qemu-arch.sh):
#   NB_LOG        serial transcript path (log_file -a)
#   NB_MEDIA      disk (default) | cd — which attached media boots the guest
#   NB_QEMU_ARGV  selftest override: full replacement argv for spawn
# The 8-minute budget: a TCG arm64 boot is slow, and the banner block (the
# first thing to see the kernel) must live through it. NB_TIMEOUT_GLOBAL
# shrinks it for the selftest so a broken arm fails in seconds, not 8 minutes.
if {[info exists env(NB_TIMEOUT_GLOBAL)] && $env(NB_TIMEOUT_GLOBAL) ne ""} {
    set timeout [expr {$env(NB_TIMEOUT_GLOBAL) + 0}]
} else {
    set timeout 480
}
log_file -a $env(NB_LOG)
log_user 1

set accel_flags [split $env(ACCEL_FLAGS) " "]
set net_args    [split $env(NET_ARGS) " "]
set video_args  [split $env(VIDEO_ARGS) " "]
set disk_args   [split $env(DISK_ARGS) " "]
set cd_args     [split $env(CD_ARGS) " "]
# NB_MEDIA=cd is the live-ISO shape (virt has no IDE: the ISO must ride the
# virtio-scsi CD); everything else boots the virtio disk.
if {[info exists env(NB_MEDIA)] && $env(NB_MEDIA) eq "cd"} {
    set media_args $cd_args
} else {
    set media_args $disk_args
}

if {[info exists env(NB_QEMU_ARGV)] && $env(NB_QEMU_ARGV) ne ""} {
    # selftest: a fake guest stands in for qemu
    set spawn_args [split $env(NB_QEMU_ARGV) " "]
} else {
    set spawn_args [concat [list $env(QEMU) -m 4G -machine $env(MACHINE) -bios $env(FW)] \
                           $accel_flags $media_args $net_args $video_args \
                           [list -display none -serial stdio -no-reboot]]
}
eval spawn $spawn_args
