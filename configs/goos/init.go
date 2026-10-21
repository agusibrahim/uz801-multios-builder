package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

func logMsg(format string, args ...any) {
	msg := fmt.Sprintf("[GoOS-PID1] "+format+"\n", args...)
	_, _ = os.Stdout.WriteString(msg)
	if f, err := os.OpenFile("/dev/kmsg", os.O_WRONLY, 0644); err == nil {
		_, _ = f.WriteString("<6>" + msg)
		_ = f.Close()
	}
}

func mountFS(source, target, fstype string, flags uintptr, data string) {
	_ = os.MkdirAll(target, 0755)
	_ = syscall.Mount(source, target, fstype, flags, data)
}

func writeSys(path, val string) {
	_ = os.WriteFile(path, []byte(val), 0644)
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Env = os.Environ()
	return cmd.Run()
}

func setupPartlabels() {
	_ = os.MkdirAll("/dev/disk/by-partlabel", 0755)
	matches, _ := filepath.Glob("/sys/block/mmcblk0/mmcblk0p*/uevent")
	for _, ueventPath := range matches {
		b, err := os.ReadFile(ueventPath)
		if err != nil {
			continue
		}
		var devName, partName string
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(line, "DEVNAME=") {
				devName = strings.TrimSpace(strings.TrimPrefix(line, "DEVNAME="))
			} else if strings.HasPrefix(line, "PARTNAME=") {
				partName = strings.TrimSpace(strings.TrimPrefix(line, "PARTNAME="))
			}
		}
		if devName != "" && partName != "" {
			linkPath := filepath.Join("/dev/disk/by-partlabel", partName)
			_ = os.Remove(linkPath)
			_ = os.Symlink("/dev/"+devName, linkPath)
		}
	}
}

func supervise(name string, bin string, args ...string) {
	go func() {
		for {
			resolved, err := exec.LookPath(bin)
			if err != nil {
				time.Sleep(5 * time.Second)
				continue
			}
			logMsg("Starting supervised daemon: %s (%s)", name, resolved)
			cmd := exec.Command(resolved, args...)
			cmd.Env = os.Environ()
			f, err := os.OpenFile("/run/"+name+".log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
			if err == nil {
				cmd.Stdout = f
				cmd.Stderr = f
			}
			err = cmd.Run()
			if f != nil {
				_ = f.Close()
			}
			logMsg("Daemon %s exited (%v), restarting in 2s...", name, err)
			time.Sleep(2 * time.Second)
		}
	}()
}

func reapZombies() {
	sigCh := make(chan os.Signal, 16)
	signal.Notify(sigCh, syscall.SIGCHLD)
	go func() {
		for range sigCh {
			for {
				var status syscall.WaitStatus
				pid, err := syscall.Wait4(-1, &status, syscall.WNOHANG, nil)
				if pid <= 0 || err != nil {
					break
				}
			}
		}
	}()
}

func ifaceHasIPv4(name string) bool {
	nif, err := net.InterfaceByName(name)
	if err != nil {
		return false
	}
	addrs, _ := nif.Addrs()
	for _, a := range addrs {
		if !strings.Contains(a.String(), ":") {
			return true
		}
	}
	return false
}

func main() {
	prog := filepath.Base(os.Args[0])
	if prog == "reboot" || prog == "poweroff" || prog == "halt" {
		syscall.Sync()
		if len(os.Args) > 1 && (os.Args[1] == "bootloader" || os.Args[1] == "edl") {
			arg := append([]byte(os.Args[1]), 0)
			_, _, _ = syscall.Syscall6(
				syscall.SYS_REBOOT,
				uintptr(0xfee1dead),
				uintptr(0x28121969),
				uintptr(0xa1b2c3d4),
				uintptr(unsafe.Pointer(&arg[0])),
				0, 0,
			)
		}
		if prog == "poweroff" || prog == "halt" {
			_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
		} else {
			_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART)
		}
		os.Exit(0)
	}

	_ = os.Setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	_ = os.Setenv("HOME", "/root")
	_ = os.Setenv("LC_ALL", "C")

	// 1. Mount early virtual filesystems directly in Go
	mountFS("proc", "/proc", "proc", syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, "")
	mountFS("sysfs", "/sys", "sysfs", syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, "")
	mountFS("devtmpfs", "/dev", "devtmpfs", syscall.MS_NOSUID, "mode=0755")
	mountFS("devpts", "/dev/pts", "devpts", syscall.MS_NOSUID|syscall.MS_NOEXEC, "gid=5,mode=0620")
	mountFS("tmpfs", "/dev/shm", "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=1777")
	mountFS("tmpfs", "/run", "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=0755")
	mountFS("tmpfs", "/tmp", "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=1777")
	mountFS("configfs", "/sys/kernel/config", "configfs", 0, "")

	_ = os.MkdirAll("/run/dbus", 0755)
	_ = os.MkdirAll("/run/lock", 0755)
	_ = os.MkdirAll("/var/log", 0755)

	logMsg("Booting UZ801 GoOS v1.0 (Pure Go PID 1 Appliance Firmware) on MSM8916...")

	reapZombies()

	// 2. Remount rootfs rw & mount /boot ro
	_ = syscall.Mount("/dev/mmcblk0p14", "/", "ext4", syscall.MS_REMOUNT, "rw,noatime,commit=1")
	_ = os.MkdirAll("/boot", 0755)
	_ = syscall.Mount("/dev/mmcblk0p13", "/boot", "ext2", syscall.MS_RDONLY|syscall.MS_NOATIME, "")

	// 3. Expand rootfs on first boot
	if _, err := os.Stat("/var/lib/expand-rootfs.done"); err != nil {
		logMsg("First boot detected: expanding /dev/mmcblk0p14 rootfs...")
		_ = run("resize2fs", "/dev/mmcblk0p14")
		_ = os.MkdirAll("/var/lib", 0755)
		_ = os.WriteFile("/var/lib/expand-rootfs.done", []byte("1\n"), 0644)
		syscall.Sync()
	}

	// 4. Hostname & loopback & sysctl
	_ = syscall.Sethostname([]byte("uz801-goos"))
	_ = run("ip", "link", "set", "lo", "up")
	_ = run("ip", "addr", "add", "127.0.0.1/8", "dev", "lo")
	writeSys("/proc/sys/net/ipv4/ip_forward", "1")
	writeSys("/proc/sys/net/ipv4/conf/all/rp_filter", "2")
	writeSys("/proc/sys/net/ipv4/conf/default/rp_filter", "2")

	// 5. Populate /dev/disk/by-partlabel for rmtfs
	setupPartlabels()

	// 6. Load hardware kernel modules
	mods := []string{
		"libcomposite", "usb_f_ncm", "usb_f_fs", "zram",
		"qcom_wcnss_pil", "wcn36xx",
		"qcom_q6v5_mss", "qcom_bam_dmux", "rpmsg_wwan_ctrl",
		"nft_limit", "nft_compat", "nft_chain_nat", "xt_MASQUERADE",
	}
	for _, m := range mods {
		_ = run("modprobe", m)
	}

	// 7. Configure 256MB LZ4 ZRAM swap
	writeSys("/sys/block/zram0/reset", "1")
	writeSys("/sys/block/zram0/comp_algorithm", "lz4")
	writeSys("/sys/block/zram0/disksize", "256M")
	if err := run("mkswap", "/dev/zram0"); err == nil {
		_ = run("swapon", "/dev/zram0")
	}

	// 8. Bring up USB Gadget (ADB + NCM 192.168.42.1 + dnsmasq) immediately!
	logMsg("Initializing USB Gadget (ADB + NCM 192.168.42.1)...")
	_ = run("/usr/sbin/usb-gadget", "start")

	// 9. Start eudev coldplug so NetworkManager & ModemManager see all devices
	_ = os.MkdirAll("/var/lib/dbus", 0755)
	_ = os.MkdirAll("/etc/dropbear", 0755)
	_ = run("dbus-uuidgen", "--ensure")
	_ = run("udevd", "--daemon")
	_ = run("udevadm", "trigger", "--type=subsystems", "--action=add")
	_ = run("udevadm", "trigger", "--type=devices", "--action=add")
	_ = run("udevadm", "settle", "--timeout=5")

	// 10. Start core supervised daemons from Go PID 1
	supervise("rmtfs", "rmtfs", "-P", "-r", "-s")
	supervise("dbus", "dbus-daemon", "--system", "--nofork", "--nopidfile")
	time.Sleep(600 * time.Millisecond)
	supervise("wpa_supplicant", "wpa_supplicant", "-u", "-s", "-O", "/run/wpa_supplicant")
	supervise("ModemManager", "ModemManager")
	supervise("NetworkManager", "NetworkManager", "--no-daemon")
	supervise("dropbear", "dropbear", "-F", "-E", "-R")
	supervise("uz801-dashboard", "uz801-dashboard")

	// 11. Background 4G LTE autoconnect & HTTP Date clock sync (runs only until connected!)
	go func() {
		client := &http.Client{Timeout: 4 * time.Second}
		timeSynced := false
		for i := 0; i < 30; i++ {
			_ = run("ip", "link", "set", "usb0", "up")
			if !ifaceHasIPv4("wwan0") {
				if run("mmcli", "-m", "0") == nil {
					_ = run("mmcli", "-m", "0", "--set-power-state-on")
					_ = run("mmcli", "-m", "0", "-e")
					_ = run("nmcli", "connection", "up", "lte")
				}
			}
			if !timeSynced && ifaceHasIPv4("wwan0") {
				if resp, err := client.Head("http://1.1.1.1"); err == nil {
					dateHdr := resp.Header.Get("Date")
					_ = resp.Body.Close()
					if t, err := http.ParseTime(dateHdr); err == nil {
						tv := syscall.NsecToTimeval(t.UnixNano())
						if syscall.Settimeofday(&tv) == nil {
							timeSynced = true
							logMsg("System clock synchronized via HTTP Date: %s", t.Format(time.RFC3339))
						}
					}
				}
			}
			if timeSynced && ifaceHasIPv4("wwan0") {
				break
			}
			time.Sleep(5 * time.Second)
		}
	}()

	logMsg("UZ801 GoOS PID 1 initialization complete. Entering supervisor loop.")
	for {
		time.Sleep(60 * time.Second)
	}
}
