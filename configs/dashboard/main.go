package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed static/*
var staticEmbed embed.FS

var (
	cpuMu          sync.Mutex
	lastCPUIdle    uint64
	lastCPUTot     uint64
	lastCPUPct     float64
	signalSetupRun bool

	watchdogMu        sync.Mutex
	watchdogEnabled   = true
	watchdogLastCheck string
	watchdogRestarts  int

	storeMu   sync.Mutex
	storePath = "/etc/uz801-hotspot-store.json"
	appStore  = &HotspotStore{
		HotspotConfig: HotspotConfig{
			Active:        true,
			SSID:          "UZ801-4G-Hotspot",
			Password:      "",
			Band:          "bg",
			Channel:       6,
			CaptivePortal: true,
			MaxClients:    10,
		},
		Vouchers:       []*Voucher{},
		BlockedMACs:    map[string]string{},
		ClientNicknames: map[string]string{},
		ClientQuotasMB:  map[string]int64{},
		ClientUsedBytes: map[string]uint64{},
		PortalDesign: PortalDesign{
			BrandName:       "Kaylaa 4G Hotspot",
			BadgeText:       "4G LTE High-Speed WiFi",
			Title:           "Selamat Datang di Layanan Internet",
			Subtitle:        "Masukkan kode voucher Anda untuk mulai terhubung ke internet berkecepatan tinggi.",
			Announcement:    "Butuh voucher? Hubungi Admin / Kasir untuk pembelian kode akses.",
			AdminContact:    "WA: 0812-3456-7890",
			AccentColor:     "#18181b",
			BackgroundStyle: "stone",
			ButtonText:      "Hubungkan ke Internet",
			FooterText:      "Powered by UZ801 Mainline 6.12",
			ShowPackages:    true,
			ShowTrialBtn:    false,
			TrialMins:       15,
			Packages: []PortalPackage{
				{Name: "Paket Hemat 3 Jam", Price: "Rp 2.000", Quota: "500 MB", Duration: "3 Jam"},
				{Name: "Paket Harian Puas", Price: "Rp 5.000", Quota: "2 GB", Duration: "24 Jam"},
				{Name: "Paket Mingguan", Price: "Rp 20.000", Quota: "10 GB", Duration: "7 Hari"},
			},
			CustomCSS: "",
		},
	}
)

type PortalPackage struct {
	Name     string `json:"name"`
	Price    string `json:"price"`
	Quota    string `json:"quota"`
	Duration string `json:"duration"`
}

type PortalDesign struct {
	BrandName       string          `json:"brand_name"`
	BadgeText       string          `json:"badge_text"`
	Title           string          `json:"title"`
	Subtitle        string          `json:"subtitle"`
	Announcement    string          `json:"announcement"`
	AdminContact    string          `json:"admin_contact"`
	AccentColor     string          `json:"accent_color"`
	BackgroundStyle string          `json:"background_style"`
	ButtonText      string          `json:"button_text"`
	FooterText      string          `json:"footer_text"`
	ShowPackages    bool            `json:"show_packages"`
	ShowTrialBtn    bool            `json:"show_trial_btn"`
	TrialMins       int             `json:"trial_mins"`
	Packages        []PortalPackage `json:"packages"`
	CustomCSS       string          `json:"custom_css"`
}

type HotspotConfig struct {
	Active        bool   `json:"active"`
	SSID          string `json:"ssid"`
	Password      string `json:"password"`
	Band          string `json:"band"`
	Channel       int    `json:"channel"`
	CaptivePortal bool   `json:"captive_portal"`
	MaxClients    int    `json:"max_clients"`
}

type Voucher struct {
	Code          string   `json:"code"`
	Label         string   `json:"label"`
	QuotaMB       int64    `json:"quota_mb"`        // 0 = unlimited
	UsedBytes     uint64   `json:"used_bytes"`
	DurationMins  int64    `json:"duration_mins"`   // 0 = unlimited, starts from first login
	SpeedKbps     int      `json:"speed_kbps"`      // 0 = unlimited
	MaxDevices    int      `json:"max_devices"`
	Status        string   `json:"status"`          // unused | active | expired | exhausted | disabled
	CreatedAt     string   `json:"created_at"`
	ActivatedAt   int64    `json:"activated_at"`    // unix timestamp
	ExpiresAt     int64    `json:"expires_at"`      // unix timestamp
	AssignedMACs  []string `json:"assigned_macs"`
	AssignedIPs   []string `json:"assigned_ips"`
}

type ConnectedClient struct {
	MAC           string `json:"mac"`
	IP            string `json:"ip"`
	Hostname      string `json:"hostname"`
	Nickname      string `json:"nickname"`
	Interface     string `json:"interface"` // wlan0 | usb0
	SignalDBm     string `json:"signal_dbm"`
	ConnectedSec  int64  `json:"connected_sec"`
	RxBytes       uint64 `json:"rx_bytes"`
	TxBytes       uint64 `json:"tx_bytes"`
	TotalBytes    uint64 `json:"total_bytes"`
	QuotaLimitMB  int64  `json:"quota_limit_mb"`
	VoucherCode   string `json:"voucher_code"`
	VoucherExpiry int64  `json:"voucher_expiry"`
	Blocked       bool   `json:"blocked"`
	Reachable     string `json:"state"`
}

type HotspotStore struct {
	HotspotConfig   HotspotConfig     `json:"hotspot_config"`
	Vouchers        []*Voucher        `json:"vouchers"`
	BlockedMACs     map[string]string `json:"blocked_macs"`
	ClientNicknames map[string]string `json:"client_nicknames"`
	ClientQuotasMB  map[string]int64  `json:"client_quotas_mb"`
	ClientUsedBytes map[string]uint64 `json:"client_used_bytes"`
	PortalDesign    PortalDesign      `json:"portal_design"`
}

func loadStore() {
	storeMu.Lock()
	defer storeMu.Unlock()
	if _, err := os.Stat("/etc"); err != nil {
		storePath = "/tmp/uz801-hotspot-store.json"
	}
	b, err := os.ReadFile(storePath)
	if err != nil {
		// Try /tmp fallback on macOS preview
		b, err = os.ReadFile("/tmp/uz801-hotspot-store.json")
	}
	if err == nil && len(b) > 0 {
		_ = json.Unmarshal(b, appStore)
		// Ensure CaptivePortal defaults to true unless explicitly toggled
	}
	if appStore.BlockedMACs == nil {
		appStore.BlockedMACs = map[string]string{}
	}
	if appStore.ClientNicknames == nil {
		appStore.ClientNicknames = map[string]string{}
	}
	if appStore.ClientQuotasMB == nil {
		appStore.ClientQuotasMB = map[string]int64{}
	}
	if appStore.ClientUsedBytes == nil {
		appStore.ClientUsedBytes = map[string]uint64{}
	}
	// Seed sample vouchers if empty so user immediately sees how it works
	if len(appStore.Vouchers) == 0 {
		now := time.Now().Format("2006-01-02 15:04")
		appStore.Vouchers = []*Voucher{
			{
				Code:         "TAMU-1GB",
				Label:        "Paket Tamu Harian",
				QuotaMB:      1024,
				DurationMins: 1440,
				SpeedKbps:    5000,
				MaxDevices:   1,
				Status:       "unused",
				CreatedAt:    now,
				AssignedMACs: []string{},
				AssignedIPs:  []string{},
			},
			{
				Code:         "HEMAT-500M",
				Label:        "Voucher 3 Jam",
				QuotaMB:      500,
				DurationMins: 180,
				SpeedKbps:    2000,
				MaxDevices:   1,
				Status:       "unused",
				CreatedAt:    now,
				AssignedMACs: []string{},
				AssignedIPs:  []string{},
			},
			{
				Code:         "VIP-UNLIMITED",
				Label:        "Akses Penuh 30 Hari",
				QuotaMB:      0,
				DurationMins: 43200,
				SpeedKbps:    0,
				MaxDevices:   3,
				Status:       "unused",
				CreatedAt:    now,
				AssignedMACs: []string{},
				AssignedIPs:  []string{},
			},
		}
		saveStoreLocked()
	}
}

func saveStoreLocked() {
	b, err := json.MarshalIndent(appStore, "", "  ")
	if err != nil {
		return
	}
	if err := os.WriteFile(storePath, b, 0644); err != nil {
		_ = os.WriteFile("/tmp/uz801-hotspot-store.json", b, 0644)
	}
}

func genCode(prefix string, length int) string {
	const chars = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	buf := make([]byte, length)
	_, _ = rand.Read(buf)
	var sb strings.Builder
	if prefix != "" {
		sb.WriteString(prefix)
		sb.WriteString("-")
	}
	for i := 0; i < length; i++ {
		sb.WriteByte(chars[int(buf[i])%len(chars)])
	}
	return sb.String()
}

func runCmd(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C")
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err
}

func readFileTrim(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func writeJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func sampleCPU() float64 {
	cpuMu.Lock()
	defer cpuMu.Unlock()
	raw := readFileTrim("/proc/stat")
	if raw == "" {
		return lastCPUPct
	}
	line := strings.Split(raw, "\n")[0]
	fields := strings.Fields(line)
	if len(fields) < 5 || fields[0] != "cpu" {
		return lastCPUPct
	}
	var total, idle uint64
	for i, f := range fields[1:] {
		v, _ := strconv.ParseUint(f, 10, 64)
		total += v
		if i == 3 || i == 4 {
			idle += v
		}
	}
	if lastCPUTot > 0 && total > lastCPUTot {
		dTot := float64(total - lastCPUTot)
		dIdle := float64(idle - lastCPUIdle)
		lastCPUPct = ((dTot - dIdle) / dTot) * 100.0
		if lastCPUPct < 0 {
			lastCPUPct = 0
		}
		if lastCPUPct > 100 {
			lastCPUPct = 100
		}
	}
	lastCPUTot = total
	lastCPUIdle = idle
	return lastCPUPct
}

type ThermalSensor struct {
	Zone string  `json:"zone"`
	Type string  `json:"type"`
	Temp float64 `json:"temp_c"`
}

func getThermals() []ThermalSensor {
	var out []ThermalSensor
	matches, _ := filepath.Glob("/sys/class/thermal/thermal_zone*")
	sort.Strings(matches)
	for _, m := range matches {
		tStr := readFileTrim(filepath.Join(m, "temp"))
		tVal, err := strconv.ParseFloat(tStr, 64)
		if err != nil {
			continue
		}
		if tVal > 1000 {
			tVal = tVal / 1000.0
		}
		out = append(out, ThermalSensor{
			Zone: filepath.Base(m),
			Type: readFileTrim(filepath.Join(m, "type")),
			Temp: tVal,
		})
	}
	return out
}

type NetInterface struct {
	Name    string   `json:"name"`
	State   string   `json:"state"`
	MAC     string   `json:"mac"`
	MTU     string   `json:"mtu"`
	IPv4    []string `json:"ipv4"`
	IPv6    []string `json:"ipv6"`
	RxBytes uint64   `json:"rx_bytes"`
	TxBytes uint64   `json:"tx_bytes"`
	RxPkts  uint64   `json:"rx_packets"`
	TxPkts  uint64   `json:"tx_packets"`
}

func getInterfaces() []NetInterface {
	var list []NetInterface
	ipOut, _ := runCmd(2*time.Second, "ip", "-o", "addr", "show")
	ipv4Map := map[string][]string{}
	ipv6Map := map[string][]string{}
	for _, line := range strings.Split(ipOut, "\n") {
		f := strings.Fields(line)
		if len(f) >= 4 {
			ifname := f[1]
			family := f[2]
			cidr := f[3]
			if family == "inet" {
				ipv4Map[ifname] = append(ipv4Map[ifname], cidr)
			} else if family == "inet6" {
				ipv6Map[ifname] = append(ipv6Map[ifname], cidr)
			}
		}
	}

	raw := readFileTrim("/proc/net/dev")
	for _, line := range strings.Split(raw, "\n") {
		if !strings.Contains(line, ":") {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		ifname := strings.TrimSpace(parts[0])
		if ifname == "lo" || (strings.HasPrefix(ifname, "wwan") && ifname != "wwan0") {
			continue
		}
		fields := strings.Fields(parts[1])
		if len(fields) < 10 {
			continue
		}
		rxB, _ := strconv.ParseUint(fields[0], 10, 64)
		rxP, _ := strconv.ParseUint(fields[1], 10, 64)
		txB, _ := strconv.ParseUint(fields[8], 10, 64)
		txP, _ := strconv.ParseUint(fields[9], 10, 64)
		state := readFileTrim("/sys/class/net/" + ifname + "/operstate")
		mac := readFileTrim("/sys/class/net/" + ifname + "/address")
		mtu := readFileTrim("/sys/class/net/" + ifname + "/mtu")
		list = append(list, NetInterface{
			Name:    ifname,
			State:   state,
			MAC:     mac,
			MTU:     mtu,
			IPv4:    ipv4Map[ifname],
			IPv6:    ipv6Map[ifname],
			RxBytes: rxB,
			TxBytes: txB,
			RxPkts:  rxP,
			TxPkts:  txP,
		})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	return list
}

type LEDInfo struct {
	Name          string   `json:"name"`
	Brightness    int      `json:"brightness"`
	MaxBrightness int      `json:"max_brightness"`
	ActiveTrigger string   `json:"active_trigger"`
	Triggers      []string `json:"triggers"`
}

func getLEDs() []LEDInfo {
	var leds []LEDInfo
	entries, _ := os.ReadDir("/sys/class/leds")
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, "mmc") {
			continue
		}
		base := "/sys/class/leds/" + name
		bVal, _ := strconv.Atoi(readFileTrim(base + "/brightness"))
		maxVal, _ := strconv.Atoi(readFileTrim(base + "/max_brightness"))
		if maxVal == 0 {
			maxVal = 255
		}
		trigRaw := readFileTrim(base + "/trigger")
		var trigs []string
		active := "none"
		for _, t := range strings.Fields(trigRaw) {
			if strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]") {
				active = strings.Trim(t, "[]")
				trigs = append(trigs, active)
			} else {
				trigs = append(trigs, t)
			}
		}
		leds = append(leds, LEDInfo{
			Name:          name,
			Brightness:    bVal,
			MaxBrightness: maxVal,
			ActiveTrigger: active,
			Triggers:      trigs,
		})
	}
	return leds
}

func getOSPrettyName() (string, string) {
	raw := readFileTrim("/etc/os-release")
	pretty := "Linux (MSM8916)"
	id := "linux"
	for _, line := range strings.Split(raw, "\n") {
		if strings.HasPrefix(line, "PRETTY_NAME=") {
			pretty = strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), `"'`)
		} else if strings.HasPrefix(line, "ID=") {
			id = strings.Trim(strings.TrimPrefix(line, "ID="), `"'`)
		}
	}
	return pretty, id
}

func getInitSystem() string {
	comm := readFileTrim("/proc/1/comm")
	if comm != "" {
		return comm
	}
	return "init"
}

func getMemoryInfo() map[string]uint64 {
	res := map[string]uint64{}
	raw := readFileTrim("/proc/meminfo")
	for _, line := range strings.Split(raw, "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 {
			k := strings.TrimSuffix(f[0], ":")
			v, _ := strconv.ParseUint(f[1], 10, 64)
			res[k] = v * 1024
		}
	}
	return res
}

func getDiskInfo() map[string]any {
	out, _ := runCmd(2*time.Second, "df", "-k", "/")
	lines := strings.Split(out, "\n")
	if len(lines) >= 2 {
		f := strings.Fields(lines[len(lines)-1])
		if len(f) >= 5 {
			totKB, _ := strconv.ParseUint(f[1], 10, 64)
			usedKB, _ := strconv.ParseUint(f[2], 10, 64)
			availKB, _ := strconv.ParseUint(f[3], 10, 64)
			return map[string]any{
				"total_bytes": totKB * 1024,
				"used_bytes":  usedKB * 1024,
				"avail_bytes": availKB * 1024,
				"use_pct":     strings.TrimSuffix(f[4], "%"),
			}
		}
	}
	return map[string]any{}
}

func getCPUInfo() map[string]any {
	curFreq, _ := strconv.ParseUint(readFileTrim("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"), 10, 64)
	maxFreq, _ := strconv.ParseUint(readFileTrim("/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"), 10, 64)
	minFreq, _ := strconv.ParseUint(readFileTrim("/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq"), 10, 64)
	gov := readFileTrim("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
	availGovs := strings.Fields(readFileTrim("/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"))
	availFreqs := strings.Fields(readFileTrim("/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies"))
	return map[string]any{
		"usage_pct":             sampleCPU(),
		"cur_freq_mhz":          curFreq / 1000,
		"max_freq_mhz":          maxFreq / 1000,
		"min_freq_mhz":          minFreq / 1000,
		"governor":              gov,
		"available_governors":   availGovs,
		"available_frequencies": availFreqs,
	}
}

func getDHCPLeases() []map[string]string {
	var leases []map[string]string
	paths := []string{"/run/dnsmasq-wlan0.leases", "/run/dnsmasq-usb0.leases", "/tmp/dhcp.leases", "/var/lib/misc/dnsmasq.leases"}
	nmLeases, _ := filepath.Glob("/var/lib/NetworkManager/dnsmasq-*.leases")
	paths = append(paths, nmLeases...)
	seen := map[string]bool{}
	for _, path := range paths {
		raw := readFileTrim(path)
		if raw == "" {
			continue
		}
		for _, line := range strings.Split(raw, "\n") {
			f := strings.Fields(line)
			if len(f) >= 4 {
				mac := strings.ToLower(f[1])
				if seen[mac] {
					continue
				}
				seen[mac] = true
				leases = append(leases, map[string]string{
					"expires":  f[0],
					"mac":      mac,
					"ip":       f[2],
					"hostname": f[3],
				})
			}
		}
	}
	return leases
}

// Discover all connected clients across WiFi AP/STA and USB, with signal, bytes, and voucher status
func discoverConnectedClients() []ConnectedClient {
	leases := getDHCPLeases()
	byMAC := map[string]*ConnectedClient{}
	for _, l := range leases {
		mac := strings.ToLower(l["mac"])
		ifname := "usb0"
		if !strings.HasPrefix(l["ip"], "192.168.42.") {
			ifname = "wlan0"
		}
		byMAC[mac] = &ConnectedClient{
			MAC:       mac,
			IP:        l["ip"],
			Hostname:  l["hostname"],
			Interface: ifname,
			Reachable: "LEASED",
		}
	}

	// Merge ip neigh show
	neighOut, _ := runCmd(2*time.Second, "ip", "neigh", "show")
	for _, line := range strings.Split(neighOut, "\n") {
		f := strings.Fields(line)
		// e.g. 192.168.42.184 dev usb0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
		if len(f) >= 5 {
			ip := f[0]
			if strings.Contains(ip, ":") {
				continue // skip IPv6 link-local for primary display
			}
			var dev, mac, state string
			for i := 1; i < len(f); i++ {
				if f[i] == "dev" && i+1 < len(f) {
					dev = f[i+1]
				} else if f[i] == "lladdr" && i+1 < len(f) {
					mac = strings.ToLower(f[i+1])
				}
			}
			state = f[len(f)-1]
			if mac == "" || dev == "wwan0" {
				continue
			}
			c, ok := byMAC[mac]
			if !ok {
				c = &ConnectedClient{
					MAC:       mac,
					IP:        ip,
					Hostname:  "*",
					Interface: dev,
				}
				byMAC[mac] = c
			}
			if c.IP == "" {
				c.IP = ip
			}
			if dev != "" {
				c.Interface = dev
			}
			c.Reachable = state
		}
	}

	// Merge WiFi stations from iw dev wlan0 station dump
	iwOut, err := runCmd(2*time.Second, "iw", "dev", "wlan0", "station", "dump")
	if err == nil && iwOut != "" {
		var cur *ConnectedClient
		for _, line := range strings.Split(iwOut, "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "Station ") {
				f := strings.Fields(line)
				if len(f) >= 2 {
					mac := strings.ToLower(f[1])
					c, ok := byMAC[mac]
					if !ok {
						c = &ConnectedClient{
							MAC:       mac,
							Hostname:  "WiFi-Client",
							Interface: "wlan0",
							Reachable: "ASSOC",
						}
						byMAC[mac] = c
					}
					cur = c
				}
			} else if cur != nil {
				if strings.HasPrefix(line, "signal:") {
					cur.SignalDBm = strings.TrimSpace(strings.TrimPrefix(line, "signal:"))
				} else if strings.HasPrefix(line, "rx bytes:") {
					v, _ := strconv.ParseUint(strings.TrimSpace(strings.TrimPrefix(line, "rx bytes:")), 10, 64)
					cur.RxBytes = v
				} else if strings.HasPrefix(line, "tx bytes:") {
					v, _ := strconv.ParseUint(strings.TrimSpace(strings.TrimPrefix(line, "tx bytes:")), 10, 64)
					cur.TxBytes = v
				} else if strings.HasPrefix(line, "connected time:") {
					f := strings.Fields(strings.TrimPrefix(line, "connected time:"))
					if len(f) >= 1 {
						cur.ConnectedSec, _ = strconv.ParseInt(f[0], 10, 64)
					}
				}
			}
		}
	}

	// Read iptables accounting per IP from UZ801_CAPTIVE & FORWARD
	iptOut, _ := runCmd(2*time.Second, "iptables", "-L", "UZ801_CAPTIVE", "-v", "-n", "-x")
	ipBytes := map[string]uint64{}
	for _, line := range strings.Split(iptOut, "\n") {
		f := strings.Fields(line)
		if len(f) >= 9 && f[2] == "ACCEPT" {
			b, err := strconv.ParseUint(f[1], 10, 64)
			if err == nil && b > 0 {
				src := f[7]
				dst := f[8]
				if src != "0.0.0.0/0" {
					ipBytes[src] += b
				}
				if dst != "0.0.0.0/0" {
					ipBytes[dst] += b
				}
			}
		}
	}

	storeMu.Lock()
	defer storeMu.Unlock()

	var result []ConnectedClient
	for _, c := range byMAC {
		c.TotalBytes = c.RxBytes + c.TxBytes
		if c.IP != "" && ipBytes[c.IP] > c.TotalBytes {
			c.TotalBytes = ipBytes[c.IP]
		}
		if savedUsed := appStore.ClientUsedBytes[c.MAC]; savedUsed > c.TotalBytes {
			c.TotalBytes = savedUsed
		} else if c.TotalBytes > savedUsed {
			appStore.ClientUsedBytes[c.MAC] = c.TotalBytes
		}
		c.Nickname = appStore.ClientNicknames[c.MAC]
		c.QuotaLimitMB = appStore.ClientQuotasMB[c.MAC]
		_, c.Blocked = appStore.BlockedMACs[c.MAC]

		// Match voucher assigned to this MAC or IP
		for _, v := range appStore.Vouchers {
			if v.Status != "active" {
				continue
			}
			for _, m := range v.AssignedMACs {
				if strings.EqualFold(m, c.MAC) {
					c.VoucherCode = v.Code
					c.VoucherExpiry = v.ExpiresAt
					if v.QuotaMB > 0 {
						c.QuotaLimitMB = v.QuotaMB
					}
					break
				}
			}
		}
		if c.Interface == "wlan0" && strings.HasPrefix(c.IP, "192.168.43.") && appStore.HotspotConfig.CaptivePortal && !c.Blocked {
			if c.VoucherCode == "" && c.QuotaLimitMB == 0 {
				c.Reachable = "LOCKED (Captive)"
			} else {
				c.Reachable = "AUTHORIZED"
			}
		}
		result = append(result, *c)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].IP < result[j].IP })
	return result
}

func getDNSServers() []string {
	var servers []string
	raw := readFileTrim("/etc/resolv.conf")
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "nameserver") {
			f := strings.Fields(line)
			if len(f) >= 2 {
				servers = append(servers, f[1])
			}
		}
	}
	return servers
}

func getUSBGadgetConfig() map[string]any {
	raw := readFileTrim("/etc/usb-gadget.conf")
	useNCM := true
	enableOTG := false
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "USE_NCM=0") {
			useNCM = false
		}
		if strings.HasPrefix(line, "ENABLE_OTG=1") {
			enableOTG = true
		}
	}
	udc := readFileTrim("/sys/kernel/config/usb_gadget/msm8916/UDC")
	role := readFileTrim("/sys/class/udc/ci_hdrc.0/device/role")
	return map[string]any{
		"mode":       map[bool]string{true: "NCM (macOS / Linux)", false: "RNDIS (Windows)"}[useNCM],
		"use_ncm":    useNCM,
		"enable_otg": enableOTG,
		"udc":        udc,
		"usb_role":   role,
	}
}

func getRoutesAndNAT() map[string]any {
	routeOut, _ := runCmd(2*time.Second, "ip", "route", "show", "default")
	ipForward := readFileTrim("/proc/sys/net/ipv4/ip_forward") == "1"
	primaryDev := ""
	var defaults []string
	for _, l := range strings.Split(routeOut, "\n") {
		l = strings.TrimSpace(l)
		if l == "" {
			continue
		}
		defaults = append(defaults, l)
		if primaryDev == "" {
			f := strings.Fields(l)
			for i := 0; i < len(f)-1; i++ {
				if f[i] == "dev" {
					primaryDev = f[i+1]
					break
				}
			}
		}
	}
	watchdogMu.Lock()
	wdEn := watchdogEnabled
	wdLast := watchdogLastCheck
	wdRestarts := watchdogRestarts
	watchdogMu.Unlock()

	return map[string]any{
		"primary_dev":       primaryDev,
		"default_routes":    defaults,
		"ip_forward":        ipForward,
		"dns_servers":       getDNSServers(),
		"usb_gadget":        getUSBGadgetConfig(),
		"watchdog_enabled":  wdEn,
		"watchdog_last":     wdLast,
		"watchdog_restarts": wdRestarts,
	}
}

func extractKV(kvOut, key string) string {
	for _, line := range strings.Split(kvOut, "\n") {
		idx := strings.Index(line, ":")
		if idx <= 0 {
			continue
		}
		k := strings.TrimSpace(line[:idx])
		if k == key {
			val := strings.TrimSpace(line[idx+1:])
			if val != "--" {
				return val
			}
			return ""
		}
	}
	return ""
}

func getModemStatus() map[string]any {
	out, err := runCmd(3*time.Second, "mmcli", "-m", "0", "-K")
	modemIdx := "0"
	if err != nil {
		listOut, _ := runCmd(2*time.Second, "mmcli", "-L")
		re := regexp.MustCompile(`/Modem/(\d+)`)
		m := re.FindStringSubmatch(listOut)
		if len(m) >= 2 {
			modemIdx = m[1]
			out, err = runCmd(3*time.Second, "mmcli", "-m", modemIdx, "-K")
		}
	}
	if err != nil || out == "" {
		return map[string]any{
			"present": false,
			"state":   "absent",
		}
	}

	if !signalSetupRun {
		_, _ = runCmd(2*time.Second, "mmcli", "-m", modemIdx, "--signal-setup=5")
		signalSetupRun = true
	}

	state := extractKV(out, "modem.generic.state")
	sigPct, _ := strconv.Atoi(extractKV(out, "modem.generic.signal-quality.value"))
	accessTech := extractKV(out, "modem.generic.access-technologies.value[1]")
	operatorName := extractKV(out, "modem.3gpp.operator-name")
	operatorCode := extractKV(out, "modem.3gpp.operator-code")
	imei := extractKV(out, "modem.3gpp.imei")
	model := extractKV(out, "modem.generic.model")
	manufacturer := extractKV(out, "modem.generic.manufacturer")
	fwRev := extractKV(out, "modem.generic.revision")
	powerState := extractKV(out, "modem.generic.power-state")
	ownNum := extractKV(out, "modem.generic.own-numbers.value[1]")
	simPath := extractKV(out, "modem.generic.sim")

	rsrp := ""
	rsrq := ""
	rssi := ""
	snr := ""
	if sigOut, err := runCmd(2*time.Second, "mmcli", "-m", modemIdx, "--signal-get", "-K"); err == nil {
		rsrp = extractKV(sigOut, "modem.signal.lte.rsrp")
		rsrq = extractKV(sigOut, "modem.signal.lte.rsrq")
		rssi = extractKV(sigOut, "modem.signal.lte.rssi")
		snr = extractKV(sigOut, "modem.signal.lte.snr")
	}

	simICCID := ""
	simIMSI := ""
	simOperator := ""
	if simPath != "" {
		simOut, err := runCmd(2*time.Second, "mmcli", "-i", simPath, "-K")
		if err == nil {
			simICCID = extractKV(simOut, "sim.properties.iccid")
			simIMSI = extractKV(simOut, "sim.properties.imsi")
			simOperator = extractKV(simOut, "sim.properties.operator-name")
		}
	}

	bearerIP := ""
	bearerPrefix := "30"
	bearerGW := ""
	bearerDNS := ""
	bearerAPN := extractKV(out, "modem.3gpp.eps.initial-bearer.settings.apn")
	bearerUptime := ""
	for i := 1; i <= 5; i++ {
		bp := extractKV(out, fmt.Sprintf("modem.generic.bearers.value[%d]", i))
		if bp == "" {
			continue
		}
		bOut, err := runCmd(2*time.Second, "mmcli", "-b", bp, "-K")
		if err != nil {
			continue
		}
		apn := extractKV(bOut, "bearer.properties.apn")
		ip := extractKV(bOut, "bearer.ipv4-config.address")
		pref := extractKV(bOut, "bearer.ipv4-config.prefix")
		gw := extractKV(bOut, "bearer.ipv4-config.gateway")
		dns := extractKV(bOut, "bearer.ipv4-config.dns.value[1]")
		dur := extractKV(bOut, "bearer.stats.duration")
		if apn != "" {
			bearerAPN = apn
		}
		if ip != "" {
			bearerIP = ip
			if pref != "" {
				bearerPrefix = pref
			}
			bearerGW = gw
			bearerDNS = dns
			bearerUptime = dur
			break
		}
	}
	_ = bearerPrefix

	return map[string]any{
		"present":       true,
		"state":         state,
		"power_state":   powerState,
		"signal_pct":    sigPct,
		"rsrp":          rsrp,
		"rsrq":          rsrq,
		"rssi":          rssi,
		"snr":           snr,
		"access_tech":   accessTech,
		"operator_name": operatorName,
		"operator_code": operatorCode,
		"imei":          imei,
		"model":         model,
		"manufacturer":  manufacturer,
		"firmware_rev":  fwRev,
		"own_number":    ownNum,
		"sim_iccid":     simICCID,
		"sim_imsi":      simIMSI,
		"sim_operator":  simOperator,
		"bearer_apn":    bearerAPN,
		"bearer_ip":     bearerIP,
		"bearer_gw":     bearerGW,
		"bearer_dns":    bearerDNS,
		"bearer_uptime": bearerUptime,
	}
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	osPretty, osID := getOSPrettyName()
	kernel, _ := runCmd(1*time.Second, "uname", "-r")
	hostname, _ := os.Hostname()
	upRaw := readFileTrim("/proc/uptime")
	var upSec float64
	if upRaw != "" {
		upSec, _ = strconv.ParseFloat(strings.Fields(upRaw)[0], 64)
	}
	loadAvg := readFileTrim("/proc/loadavg")
	mem := getMemoryInfo()
	clients := discoverConnectedClients()

	storeMu.Lock()
	hsCfg := appStore.HotspotConfig
	vouchers := appStore.Vouchers
	portalCfg := appStore.PortalDesign
	storeMu.Unlock()

	writeJSON(w, http.StatusOK, map[string]any{
		"timestamp":   time.Now().Format(time.RFC3339),
		"os_pretty":   osPretty,
		"os_id":       osID,
		"init_system": getInitSystem(),
		"kernel":      kernel,
		"hostname":    hostname,
		"uptime_sec":  uint64(upSec),
		"load_avg":    loadAvg,
		"cpu":         getCPUInfo(),
		"memory":      mem,
		"disk":        getDiskInfo(),
		"thermals":    getThermals(),
		"interfaces":  getInterfaces(),
		"modem":       getModemStatus(),
		"leds":        getLEDs(),
		"routes":      getRoutesAndNAT(),
		"dhcp_leases": getDHCPLeases(),
		"clients":     clients,
		"hotspot":     hsCfg,
		"vouchers":    vouchers,
		"portal":      portalCfg,
	})
}

// Synchronize iptables Captive Portal Walled Garden (IP-based) & nftables Bandwidth Limiter (uz801_qos)
func syncCaptiveFirewall() {
	// Map MAC -> IP from DHCP leases & ARP table
	macToIP := map[string]string{}
	for _, l := range getDHCPLeases() {
		macToIP[strings.ToLower(l["mac"])] = l["ip"]
	}
	neighOut, _ := runCmd(2*time.Second, "ip", "neigh", "show")
	for _, line := range strings.Split(neighOut, "\n") {
		f := strings.Fields(line)
		if len(f) >= 5 && !strings.Contains(f[0], ":") {
			for i := 1; i < len(f)-1; i++ {
				if f[i] == "lladdr" {
					macToIP[strings.ToLower(f[i+1])] = f[0]
				}
			}
		}
	}

	storeMu.Lock()
	captiveOn := appStore.HotspotConfig.CaptivePortal
	authorizedIPs := map[string]bool{}
	speedLimitByIP := map[string]int{} // ip -> speed_kbps

	for _, v := range appStore.Vouchers {
		if v.Status == "active" {
			for _, m := range v.AssignedMACs {
				if ip := macToIP[strings.ToLower(strings.TrimSpace(m))]; ip != "" {
					authorizedIPs[ip] = true
					if v.SpeedKbps > 0 {
						speedLimitByIP[ip] = v.SpeedKbps
					}
				}
			}
		}
	}
	for mac, q := range appStore.ClientQuotasMB {
		if q > 0 {
			if ip := macToIP[strings.ToLower(strings.TrimSpace(mac))]; ip != "" {
				authorizedIPs[ip] = true
			}
		}
	}
	blockedIPs := map[string]bool{}
	for mac := range appStore.BlockedMACs {
		if ip := macToIP[strings.ToLower(strings.TrimSpace(mac))]; ip != "" {
			blockedIPs[ip] = true
		}
	}
	storeMu.Unlock()

	// Clean up any duplicate jump rules in FORWARD and PREROUTING
	_, _ = runCmd(2*time.Second, "iptables", "-N", "UZ801_CAPTIVE")
	_, _ = runCmd(2*time.Second, "iptables", "-F", "UZ801_CAPTIVE")
	for i := 0; i < 5; i++ {
		if _, err := runCmd(1*time.Second, "iptables", "-D", "FORWARD", "-j", "UZ801_CAPTIVE"); err != nil {
			break
		}
	}
	_, _ = runCmd(2*time.Second, "iptables", "-I", "FORWARD", "1", "-j", "UZ801_CAPTIVE")

	_, _ = runCmd(2*time.Second, "iptables", "-t", "nat", "-N", "UZ801_CAPTIVE_NAT")
	_, _ = runCmd(2*time.Second, "iptables", "-t", "nat", "-F", "UZ801_CAPTIVE_NAT")
	for i := 0; i < 5; i++ {
		if _, err := runCmd(1*time.Second, "iptables", "-t", "nat", "-D", "PREROUTING", "-j", "UZ801_CAPTIVE_NAT"); err != nil {
			break
		}
	}
	_, _ = runCmd(2*time.Second, "iptables", "-t", "nat", "-I", "PREROUTING", "1", "-j", "UZ801_CAPTIVE_NAT")

	// 1. Explicitly blocked client IPs are always rejected first
	for ip := range blockedIPs {
		_, _ = runCmd(2*time.Second, "iptables", "-A", "UZ801_CAPTIVE", "-s", ip, "-j", "REJECT")
		_, _ = runCmd(2*time.Second, "iptables", "-A", "UZ801_CAPTIVE", "-d", ip, "-j", "REJECT")
	}

	// 2. Authorized voucher IPs bypass captive NAT redirect and are allowed to forward (with RX/TX byte counters)
	for ip := range authorizedIPs {
		if blockedIPs[ip] {
			continue
		}
		_, _ = runCmd(2*time.Second, "iptables", "-t", "nat", "-A", "UZ801_CAPTIVE_NAT", "-i", "wlan0", "-s", ip, "-j", "RETURN")
		_, _ = runCmd(2*time.Second, "iptables", "-A", "UZ801_CAPTIVE", "-i", "wlan0", "-s", ip, "-j", "ACCEPT")
		_, _ = runCmd(2*time.Second, "iptables", "-A", "UZ801_CAPTIVE", "-o", "wlan0", "-d", ip, "-j", "ACCEPT")
	}

	if captiveOn {
		// 3. Unauthenticated wlan0 clients: allow DNS (53), redirect HTTP (80) to 192.168.43.1:80, reject all other forwarding
		_, _ = runCmd(2*time.Second, "iptables", "-t", "nat", "-A", "UZ801_CAPTIVE_NAT", "-i", "wlan0", "-p", "udp", "--dport", "53", "-j", "REDIRECT", "--to-ports", "53")
		_, _ = runCmd(2*time.Second, "iptables", "-t", "nat", "-A", "UZ801_CAPTIVE_NAT", "-i", "wlan0", "-p", "tcp", "--dport", "80", "-j", "DNAT", "--to-destination", "192.168.43.1:80")
		_, _ = runCmd(2*time.Second, "iptables", "-A", "UZ801_CAPTIVE", "-i", "wlan0", "-p", "udp", "--dport", "53", "-j", "ACCEPT")
		_, _ = runCmd(2*time.Second, "iptables", "-A", "UZ801_CAPTIVE", "-i", "wlan0", "-p", "tcp", "--dport", "53", "-j", "ACCEPT")
		_, _ = runCmd(2*time.Second, "iptables", "-A", "UZ801_CAPTIVE", "-i", "wlan0", "-j", "REJECT")
	}

	// 4. Synchronize per-IP bandwidth rate limits via nftables (nft_limit)
	_, _ = runCmd(2*time.Second, "modprobe", "nft_limit")
	_, _ = runCmd(2*time.Second, "nft", "delete", "table", "ip", "uz801_qos")
	if len(speedLimitByIP) > 0 {
		_, _ = runCmd(2*time.Second, "nft", "add", "table", "ip", "uz801_qos")
		_, _ = runCmd(2*time.Second, "nft", "add chain ip uz801_qos forward { type filter hook forward priority -10 ; policy accept ; }")
		for ip, kbps := range speedLimitByIP {
			kbytes := kbps / 8
			if kbytes < 8 {
				kbytes = 8
			}
			burst := kbytes * 2
			_, _ = runCmd(2*time.Second, "nft", fmt.Sprintf("add rule ip uz801_qos forward ip daddr %s limit rate over %d kbytes/second burst %d kbytes drop", ip, kbytes, burst))
			_, _ = runCmd(2*time.Second, "nft", fmt.Sprintf("add rule ip uz801_qos forward ip saddr %s limit rate over %d kbytes/second burst %d kbytes drop", ip, kbytes, burst))
		}
	}
}

func isClientAuthorized(remoteIP string) bool {
	if !strings.HasPrefix(remoteIP, "192.168.43.") {
		return true
	}
	storeMu.Lock()
	captiveOn := appStore.HotspotConfig.CaptivePortal
	storeMu.Unlock()
	if !captiveOn {
		return true
	}
	clients := discoverConnectedClients()
	for _, c := range clients {
		if c.IP == remoteIP {
			if c.Blocked {
				return false
			}
			if c.VoucherCode != "" || c.QuotaLimitMB > 0 {
				return true
			}
			return false
		}
	}
	return false
}

// Client management: kick, block, unblock, set nickname/quota
func applyMACBlock(mac string, block bool) {
	syncCaptiveFirewall()
	if block && mac != "" {
		_, _ = runCmd(2*time.Second, "iw", "dev", "wlan0", "station", "del", strings.ToLower(strings.TrimSpace(mac)))
	}
}

func handleClientsAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusOK, map[string]any{"clients": discoverConnectedClients()})
		return
	}
	var req struct {
		Action   string `json:"action"` // kick | block | unblock | update | reset_usage
		MAC      string `json:"mac"`
		IP       string `json:"ip"`
		Nickname string `json:"nickname"`
		QuotaMB  int64  `json:"quota_mb"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid body"})
		return
	}
	mac := strings.ToLower(strings.TrimSpace(req.MAC))

	storeMu.Lock()
	switch req.Action {
	case "kick":
		if mac != "" {
			// Remove MAC from any active voucher so it must re-authenticate
			for _, v := range appStore.Vouchers {
				var kept []string
				for _, m := range v.AssignedMACs {
					if !strings.EqualFold(m, mac) {
						kept = append(kept, m)
					}
				}
				v.AssignedMACs = kept
				if len(v.AssignedMACs) == 0 {
					v.AssignedIPs = []string{}
				}
			}
			saveStoreLocked()
			go func(m string) {
				syncCaptiveFirewall()
				_, _ = runCmd(2*time.Second, "iw", "dev", "wlan0", "station", "del", m)
			}(mac)
		}
	case "block":
		if mac != "" {
			appStore.BlockedMACs[mac] = time.Now().Format("2006-01-02 15:04")
			saveStoreLocked()
			go applyMACBlock(mac, true)
		}
	case "unblock":
		if mac != "" {
			delete(appStore.BlockedMACs, mac)
			saveStoreLocked()
			go applyMACBlock(mac, false)
		}
	case "update":
		if mac != "" {
			if req.Nickname != "" {
				appStore.ClientNicknames[mac] = req.Nickname
			}
			appStore.ClientQuotasMB[mac] = req.QuotaMB
			saveStoreLocked()
			go syncCaptiveFirewall()
		}
	case "reset_usage":
		if mac != "" {
			delete(appStore.ClientUsedBytes, mac)
			saveStoreLocked()
		}
	}
	storeMu.Unlock()

	// Setup per-IP iptables accounting rule if IP given
	if req.IP != "" {
		_, _ = runCmd(2*time.Second, "iptables", "-C", "FORWARD", "-s", req.IP)
	}

	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "clients": discoverConnectedClients()})
}

// Voucher CRUD & Activation API
func handleVouchers(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		storeMu.Lock()
		v := appStore.Vouchers
		storeMu.Unlock()
		writeJSON(w, http.StatusOK, map[string]any{"vouchers": v})
		return
	}
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req struct {
		Action       string `json:"action"` // create | batch | delete | reset | toggle | activate
		Code         string `json:"code"`
		Prefix       string `json:"prefix"`
		Count        int    `json:"count"`
		Label        string `json:"label"`
		QuotaMB      int64  `json:"quota_mb"`
		DurationMins int64  `json:"duration_mins"`
		SpeedKbps    int    `json:"speed_kbps"`
		MaxDevices   int    `json:"max_devices"`
		ClientMAC    string `json:"client_mac"`
		ClientIP     string `json:"client_ip"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid body"})
		return
	}

	storeMu.Lock()
	defer storeMu.Unlock()

	nowStr := time.Now().Format("2006-01-02 15:04")
	if req.MaxDevices <= 0 {
		req.MaxDevices = 1
	}

	switch req.Action {
	case "create":
		code := strings.ToUpper(strings.TrimSpace(req.Code))
		if code == "" {
			code = genCode("UZ", 5)
		}
		v := &Voucher{
			Code:         code,
			Label:        req.Label,
			QuotaMB:      req.QuotaMB,
			DurationMins: req.DurationMins,
			SpeedKbps:    req.SpeedKbps,
			MaxDevices:   req.MaxDevices,
			Status:       "unused",
			CreatedAt:    nowStr,
			AssignedMACs: []string{},
			AssignedIPs:  []string{},
		}
		appStore.Vouchers = append([]*Voucher{v}, appStore.Vouchers...)
		saveStoreLocked()

	case "batch":
		cnt := req.Count
		if cnt <= 0 || cnt > 50 {
			cnt = 5
		}
		pref := strings.ToUpper(strings.TrimSpace(req.Prefix))
		if pref == "" {
			pref = "VCR"
		}
		for i := 0; i < cnt; i++ {
			v := &Voucher{
				Code:         genCode(pref, 5),
				Label:        req.Label,
				QuotaMB:      req.QuotaMB,
				DurationMins: req.DurationMins,
				SpeedKbps:    req.SpeedKbps,
				MaxDevices:   req.MaxDevices,
				Status:       "unused",
				CreatedAt:    nowStr,
				AssignedMACs: []string{},
				AssignedIPs:  []string{},
			}
			appStore.Vouchers = append([]*Voucher{v}, appStore.Vouchers...)
		}
		saveStoreLocked()

	case "delete":
		var kept []*Voucher
		for _, v := range appStore.Vouchers {
			if !strings.EqualFold(v.Code, req.Code) {
				kept = append(kept, v)
			}
		}
		appStore.Vouchers = kept
		saveStoreLocked()

	case "reset":
		for _, v := range appStore.Vouchers {
			if strings.EqualFold(v.Code, req.Code) {
				v.UsedBytes = 0
				v.Status = "unused"
				v.ActivatedAt = 0
				v.ExpiresAt = 0
				for _, m := range v.AssignedMACs {
					delete(appStore.BlockedMACs, m)
					go applyMACBlock(m, false)
				}
				v.AssignedMACs = []string{}
				v.AssignedIPs = []string{}
				break
			}
		}
		saveStoreLocked()

	case "toggle":
		for _, v := range appStore.Vouchers {
			if strings.EqualFold(v.Code, req.Code) {
				if v.Status == "disabled" {
					v.Status = "unused"
					for _, m := range v.AssignedMACs {
						delete(appStore.BlockedMACs, m)
						go applyMACBlock(m, false)
					}
				} else {
					v.Status = "disabled"
					for _, m := range v.AssignedMACs {
						appStore.BlockedMACs[m] = nowStr
						go applyMACBlock(m, true)
					}
				}
				break
			}
		}
		saveStoreLocked()

	case "activate":
		// Assign a voucher code to a client MAC/IP & start timer
		var found *Voucher
		for _, v := range appStore.Vouchers {
			if strings.EqualFold(v.Code, strings.TrimSpace(req.Code)) {
				found = v
				break
			}
		}
		if found == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "Kode voucher tidak ditemukan"})
			return
		}
		if found.Status == "disabled" || found.Status == "expired" || found.Status == "exhausted" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "Voucher sudah " + found.Status})
			return
		}
		mac := strings.ToLower(strings.TrimSpace(req.ClientMAC))
		if mac != "" {
			already := false
			for _, m := range found.AssignedMACs {
				if m == mac {
					already = true
					break
				}
			}
			if !already && len(found.AssignedMACs) >= found.MaxDevices {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": fmt.Sprintf("Batas perangkat voucher tercapai (%d perangkat)", found.MaxDevices)})
				return
			}
			if !already {
				found.AssignedMACs = append(found.AssignedMACs, mac)
			}
			delete(appStore.BlockedMACs, mac)
			go applyMACBlock(mac, false)
		}
		if req.ClientIP != "" {
			found.AssignedIPs = append(found.AssignedIPs, req.ClientIP)
		}
		if found.ActivatedAt == 0 {
			nowUnix := time.Now().Unix()
			found.ActivatedAt = nowUnix
			if found.DurationMins > 0 {
				found.ExpiresAt = nowUnix + (found.DurationMins * 60)
			}
		}
		found.Status = "active"
		saveStoreLocked()
	}

	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "vouchers": appStore.Vouchers})
	go syncCaptiveFirewall()
}

func startHotspotAP(cfg HotspotConfig) (string, error) {
	if cfg.Channel <= 0 {
		cfg.Channel = 6
	}
	// Disconnect any client WiFi profile on wlan0 first so AP mode can bind cleanly
	_, _ = runCmd(3*time.Second, "nmcli", "connection", "down", "wlan")
	_, _ = runCmd(3*time.Second, "nmcli", "connection", "down", "Kaylaa")
	_, _ = runCmd(3*time.Second, "nmcli", "connection", "modify", "wlan", "connection.autoconnect", "no")
	_, _ = runCmd(3*time.Second, "nmcli", "connection", "delete", "Hotspot")
	addArgs := []string{
		"connection", "add", "type", "wifi", "ifname", "wlan0", "con-name", "Hotspot",
		"autoconnect", "yes", "ssid", cfg.SSID,
		"802-11-wireless.mode", "ap",
		"802-11-wireless.band", "bg",
		"802-11-wireless.channel", strconv.Itoa(cfg.Channel),
		"ipv4.method", "manual",
		"ipv4.addresses", "192.168.43.1/24",
	}
	if len(cfg.Password) >= 8 {
		addArgs = append(addArgs,
			"wifi-sec.key-mgmt", "wpa-psk",
			"wifi-sec.proto", "rsn",
			"wifi-sec.pairwise", "ccmp",
			"wifi-sec.group", "ccmp",
			"wifi-sec.psk", cfg.Password,
		)
	}
	if out, err := runCmd(8*time.Second, "nmcli", addArgs...); err != nil {
		return out, err
	}
	out, err := runCmd(15*time.Second, "nmcli", "connection", "up", "Hotspot")
	if err != nil {
		return out, err
	}

	// Start dedicated DHCP server on wlan0 (192.168.43.10 - 192.168.43.250)
	if pidStr := readFileTrim("/run/dnsmasq-wlan0.pid"); pidStr != "" {
		_, _ = runCmd(2*time.Second, "kill", pidStr)
	}
	_, _ = runCmd(3*time.Second, "/usr/sbin/dnsmasq",
		"--user=root",
		"--interface=wlan0",
		"--bind-interfaces",
		"--except-interface=lo",
		"--no-resolv",
		"--server=1.1.1.1",
		"--server=8.8.8.8",
		"--filter-AAAA",
		"--dhcp-range=192.168.43.10,192.168.43.250,255.255.255.0,12h",
		"--dhcp-option=3,192.168.43.1",
		"--dhcp-option=6,192.168.43.1",
		"--dhcp-option=114,http://192.168.43.1/portal",
		"--dhcp-leasefile=/run/dnsmasq-wlan0.leases",
		"--pid-file=/run/dnsmasq-wlan0.pid",
	)

	// Enable IPv4 forwarding, NAT masquerading on wwan0, Captive Portal firewall, and ensure 4G default route is active
	_ = os.WriteFile("/proc/sys/net/ipv4/ip_forward", []byte("1"), 0644)
	_, _ = runCmd(3*time.Second, "iptables", "-t", "nat", "-A", "POSTROUTING", "-o", "wwan0", "-j", "MASQUERADE")
	_, _ = runCmd(3*time.Second, "nft", "add", "table", "ip", "uz801_nat")
	_, _ = runCmd(3*time.Second, "nft", "add", "chain", "ip", "uz801_nat", "postrouting", "{ type nat hook postrouting priority 100 ; }")
	_, _ = runCmd(3*time.Second, "nft", "add", "rule", "ip", "uz801_nat", "postrouting", "oifname", "wwan0", "masquerade")
	syncCaptiveFirewall()

	m := getModemStatus()
	if gw, _ := m["bearer_gw"].(string); gw != "" {
		_, _ = runCmd(3*time.Second, "ip", "route", "replace", "default", "via", gw, "dev", "wwan0", "metric", "50")
	}
	return out, nil
}

func stopHotspotAP() (string, error) {
	if pidStr := readFileTrim("/run/dnsmasq-wlan0.pid"); pidStr != "" {
		_, _ = runCmd(2*time.Second, "kill", pidStr)
	}
	_ = os.Remove("/run/dnsmasq-wlan0.pid")
	_, _ = runCmd(8*time.Second, "nmcli", "connection", "down", "Hotspot")
	_, _ = runCmd(3*time.Second, "nmcli", "connection", "delete", "Hotspot")
	_, _ = runCmd(3*time.Second, "nmcli", "connection", "modify", "wlan", "connection.autoconnect", "yes")
	out, err := runCmd(15*time.Second, "nmcli", "connection", "up", "wlan")
	if err != nil {
		out, err = runCmd(15*time.Second, "nmcli", "device", "connect", "wlan0")
	}
	return out, err
}

func handleHotspotConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		storeMu.Lock()
		cfg := appStore.HotspotConfig
		storeMu.Unlock()
		writeJSON(w, http.StatusOK, cfg)
		return
	}
	var req HotspotConfig
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid body"})
		return
	}
	storeMu.Lock()
	if req.SSID != "" {
		appStore.HotspotConfig.SSID = req.SSID
	}
	appStore.HotspotConfig.Password = strings.TrimSpace(req.Password)
	if req.Channel > 0 {
		appStore.HotspotConfig.Channel = req.Channel
	}
	if req.MaxClients > 0 {
		appStore.HotspotConfig.MaxClients = req.MaxClients
	}
	appStore.HotspotConfig.CaptivePortal = req.CaptivePortal
	appStore.HotspotConfig.Active = req.Active
	cfg := appStore.HotspotConfig
	saveStoreLocked()
	storeMu.Unlock()

	var out string
	var err error
	if cfg.Active {
		out, err = startHotspotAP(cfg)
	} else {
		out, err = stopHotspotAP()
		syncCaptiveFirewall()
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out, "hotspot": cfg})
}

// Background Voucher & Client Quota / Expiry Enforcer + Hotspot Auto-Start Watchdog
func startVoucherEnforcer() {
	// Ensure Hotspot AP starts automatically on boot if HotspotConfig.Active == true
	go func() {
		for i := 0; i < 15; i++ {
			time.Sleep(3 * time.Second)
			storeMu.Lock()
			cfg := appStore.HotspotConfig
			storeMu.Unlock()
			if !cfg.Active {
				return
			}
			if _, err := os.Stat("/sys/class/net/wlan0"); err == nil {
				ipOut, _ := runCmd(2*time.Second, "ip", "addr", "show", "dev", "wlan0")
				if !strings.Contains(ipOut, "192.168.43.1") {
					log.Printf("[+] Auto-starting Hotspot AP (%s) on boot...", cfg.SSID)
					_, _ = startHotspotAP(cfg)
				} else {
					// Ensure wlan0 dnsmasq and captive firewall are running
					if pidStr := readFileTrim("/run/dnsmasq-wlan0.pid"); pidStr == "" {
						_, _ = startHotspotAP(cfg)
					} else {
						syncCaptiveFirewall()
					}
					return
				}
			}
		}
	}()

	go func() {
		for {
			time.Sleep(10 * time.Second)
			storeMu.Lock()
			hsCfg := appStore.HotspotConfig
			storeMu.Unlock()
			if hsCfg.Active {
				ipOut, _ := runCmd(2*time.Second, "ip", "addr", "show", "dev", "wlan0")
				if !strings.Contains(ipOut, "192.168.43.1") {
					_, _ = startHotspotAP(hsCfg)
				}
			}
			clients := discoverConnectedClients()
			clientBytesByMAC := map[string]uint64{}
			for _, c := range clients {
				clientBytesByMAC[c.MAC] = c.TotalBytes
			}

			nowUnix := time.Now().Unix()
			storeMu.Lock()
			changed := false

			// 1. Check per-client direct quota limits
			for mac, limitMB := range appStore.ClientQuotasMB {
				if limitMB > 0 {
					used := clientBytesByMAC[mac]
					if used >= uint64(limitMB)*1048576 {
						if _, blocked := appStore.BlockedMACs[mac]; !blocked {
							appStore.BlockedMACs[mac] = "Quota Exhausted"
							changed = true
							go applyMACBlock(mac, true)
						}
					}
				}
			}

			// 2. Check active vouchers (duration expiry + byte quota)
			for _, v := range appStore.Vouchers {
				if v.Status != "active" {
					continue
				}
				var sumBytes uint64
				for _, m := range v.AssignedMACs {
					sumBytes += clientBytesByMAC[strings.ToLower(m)]
				}
				if sumBytes > v.UsedBytes {
					v.UsedBytes = sumBytes
					changed = true
				}
				// Check time expiry
				if v.ExpiresAt > 0 && nowUnix >= v.ExpiresAt {
					v.Status = "expired"
					changed = true
					for _, m := range v.AssignedMACs {
						appStore.BlockedMACs[m] = "Voucher Expired"
						go applyMACBlock(m, true)
					}
				}
				// Check quota exhaustion
				if v.QuotaMB > 0 && v.UsedBytes >= uint64(v.QuotaMB)*1048576 {
					v.Status = "exhausted"
					changed = true
					for _, m := range v.AssignedMACs {
						appStore.BlockedMACs[m] = "Voucher Quota Exhausted"
						go applyMACBlock(m, true)
					}
				}
			}

			if changed {
				saveStoreLocked()
			}
			storeMu.Unlock()
		}
	}()
}

type SMSMessage struct {
	ID        string `json:"id"`
	Number    string `json:"number"`
	Text      string `json:"text"`
	Timestamp string `json:"timestamp"`
	State     string `json:"state"`
	PDU       string `json:"pdu_type"`
}

func handleSMSList(w http.ResponseWriter, r *http.Request) {
	out, err := runCmd(4*time.Second, "mmcli", "-m", "0", "--messaging-list-sms")
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"messages": []SMSMessage{}, "raw": out})
		return
	}
	re := regexp.MustCompile(`/SMS/(\d+)`)
	matches := re.FindAllStringSubmatch(out, -1)
	var msgs []SMSMessage
	for _, m := range matches {
		id := m[1]
		sOut, err := runCmd(3*time.Second, "mmcli", "-s", id, "-K")
		if err != nil {
			continue
		}
		msgs = append(msgs, SMSMessage{
			ID:        id,
			Number:    extractKV(sOut, "sms.content.number"),
			Text:      extractKV(sOut, "sms.content.text"),
			Timestamp: extractKV(sOut, "sms.properties.timestamp"),
			State:     extractKV(sOut, "sms.properties.state"),
			PDU:       extractKV(sOut, "sms.properties.pdu-type"),
		})
	}
	sort.Slice(msgs, func(i, j int) bool {
		idI, _ := strconv.Atoi(msgs[i].ID)
		idJ, _ := strconv.Atoi(msgs[j].ID)
		return idI > idJ
	})
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs})
}

func handleSMSSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req struct {
		Number string `json:"number"`
		Text   string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Number == "" || req.Text == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "number and text required"})
		return
	}
	cleanText := strings.ReplaceAll(req.Text, "'", "")
	cleanNum := strings.ReplaceAll(req.Number, "'", "")
	arg := fmt.Sprintf("text='%s',number='%s'", cleanText, cleanNum)
	createOut, err := runCmd(8*time.Second, "mmcli", "-m", "0", "--messaging-create-sms="+arg)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": createOut})
		return
	}
	re := regexp.MustCompile(`/SMS/(\d+)`)
	m := re.FindStringSubmatch(createOut)
	if len(m) < 2 {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "could not parse SMS ID: " + createOut})
		return
	}
	smsID := m[1]
	sendOut, err := runCmd(15*time.Second, "mmcli", "-s", smsID, "--send")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": sendOut, "sms_id": smsID})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "sms_id": smsID, "output": sendOut})
}

func handleSMSDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req struct {
		ID string `json:"id"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.ID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "id required"})
		return
	}
	out, err := runCmd(5*time.Second, "mmcli", "-m", "0", "--messaging-delete-sms="+req.ID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": out})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

func handleUSSD(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		out, _ := runCmd(3*time.Second, "mmcli", "-m", "0", "--3gpp-ussd-status")
		writeJSON(w, http.StatusOK, map[string]any{"output": out})
		return
	}
	var req struct {
		Action string `json:"action"`
		Code   string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid body"})
		return
	}
	switch req.Action {
	case "cancel":
		out, _ := runCmd(5*time.Second, "mmcli", "-m", "0", "--3gpp-ussd-cancel")
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
	case "respond":
		out, err := runCmd(10*time.Second, "mmcli", "-m", "0", "--3gpp-ussd-respond="+req.Code)
		if err != nil && out == "" {
			out = "Timeout: Operator seluler (4G LTE-only tanpa jaringan 3G/VoLTE) tidak merespons sesi USSD."
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out})
	default:
		_, _ = runCmd(2*time.Second, "mmcli", "-m", "0", "--3gpp-ussd-cancel")
		out, err := runCmd(10*time.Second, "mmcli", "-m", "0", "--3gpp-ussd-initiate="+req.Code)
		if err != nil {
			out = out + "\n\n[Info]: Pada jaringan 4G LTE-only (seperti Telkomsel/by.U setelah jaringan 3G dimatikan), panggilan USSD (*888#/*363#) tidak didukung oleh operator melalui jalur data LTE tanpa VoLTE/2G. Gunakan fitur Kotak Masuk SMS & OTP di sebelah kiri untuk membaca/mengirim SMS."
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": strings.TrimSpace(out)})
	}
}

func handleModemAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req struct {
		Action string `json:"action"`
		APN    string `json:"apn"`
		IPType string `json:"ip_type"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.APN == "" {
		req.APN = "byu"
	}
	if req.IPType == "" {
		req.IPType = "ipv4"
	}
	var out string
	var err error
	switch req.Action {
	case "connect":
		_, _ = runCmd(5*time.Second, "mmcli", "-m", "0", "--set-power-state-on")
		_, _ = runCmd(5*time.Second, "mmcli", "-m", "0", "-e")
		_, _ = runCmd(4*time.Second, "nmcli", "connection", "modify", "lte", "gsm.apn", req.APN)
		out, err = runCmd(15*time.Second, "nmcli", "connection", "up", "lte")
		if err != nil {
			out, err = runCmd(20*time.Second, "mmcli", "-m", "0", fmt.Sprintf("--simple-connect=apn=%s,ip-type=%s", req.APN, req.IPType))
		}
	case "disconnect":
		_, _ = runCmd(5*time.Second, "nmcli", "connection", "down", "lte")
		out, err = runCmd(10*time.Second, "mmcli", "-m", "0", "--simple-disconnect")
	case "reset":
		go func() {
			_ = os.WriteFile("/sys/class/remoteproc/remoteproc0/state", []byte("stop"), 0644)
			_, _ = runCmd(3*time.Second, "modprobe", "-r", "qcom_bam_dmux")
			_, _ = runCmd(3*time.Second, "modprobe", "qcom_bam_dmux")
			_ = os.WriteFile("/sys/class/remoteproc/remoteproc0/state", []byte("start"), 0644)
			time.Sleep(10 * time.Second)
			_, _ = runCmd(5*time.Second, "rc-service", "modemmanager", "restart")
			_, _ = runCmd(5*time.Second, "systemctl", "restart", "ModemManager")
			time.Sleep(8 * time.Second)
			_, _ = runCmd(5*time.Second, "mmcli", "-m", "0", "--set-power-state-on")
			_, _ = runCmd(5*time.Second, "mmcli", "-m", "0", "-e")
			time.Sleep(2 * time.Second)
			_, _ = runCmd(15*time.Second, "nmcli", "connection", "up", "lte")
		}()
		out = "Restarting Qualcomm QDSP6 Modem DSP & BAM-DMUX (~20s)..."
	case "power_low":
		out, err = runCmd(8*time.Second, "mmcli", "-m", "0", "--set-power-state-low")
	case "power_on":
		out, err = runCmd(8*time.Second, "mmcli", "-m", "0", "--set-power-state-on")
		_, _ = runCmd(5*time.Second, "mmcli", "-m", "0", "-e")
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "unknown action"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out})
}

func handleLEDControl(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusOK, map[string]any{"leds": getLEDs()})
		return
	}
	var req struct {
		Preset     string `json:"preset"`
		Name       string `json:"name"`
		Trigger    string `json:"trigger"`
		Brightness *int   `json:"brightness"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid body"})
		return
	}

	setLED := func(name, trig string, bright int) {
		base := "/sys/class/leds/" + name
		if trig != "" {
			_ = os.WriteFile(base+"/trigger", []byte(trig), 0644)
		}
		if bright >= 0 {
			_ = os.WriteFile(base+"/brightness", []byte(strconv.Itoa(bright)), 0644)
		}
	}

	switch req.Preset {
	case "stealth":
		for _, l := range getLEDs() {
			setLED(l.Name, "none", 0)
		}
	case "default":
		for _, l := range getLEDs() {
			if strings.Contains(l.Name, "blue") {
				setLED(l.Name, "heartbeat", 1)
			} else if strings.Contains(l.Name, "green") {
				setLED(l.Name, "default-on", 1)
			} else {
				setLED(l.Name, "none", 0)
			}
		}
	case "netdev":
		for _, l := range getLEDs() {
			if strings.Contains(l.Name, "blue") {
				setLED(l.Name, "timer", 1)
			} else {
				setLED(l.Name, "none", 0)
			}
		}
	default:
		if req.Name != "" {
			b := -1
			if req.Brightness != nil {
				b = *req.Brightness
			}
			setLED(req.Name, req.Trigger, b)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "leds": getLEDs()})
}

func handleCPUControl(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusOK, getCPUInfo())
		return
	}
	var req struct {
		Governor   string `json:"governor"`
		MaxFreqMHz int    `json:"max_freq_mhz"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid body"})
		return
	}
	for i := 0; i < 4; i++ {
		base := fmt.Sprintf("/sys/devices/system/cpu/cpu%d/cpufreq", i)
		if req.Governor != "" {
			_ = os.WriteFile(base+"/scaling_governor", []byte(req.Governor), 0644)
		}
		if req.MaxFreqMHz > 0 {
			_ = os.WriteFile(base+"/scaling_max_freq", []byte(strconv.Itoa(req.MaxFreqMHz*1000)), 0644)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "cpu": getCPUInfo()})
}

func handleNetworkControl(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusOK, getRoutesAndNAT())
		return
	}
	var req struct {
		Action     string   `json:"action"`
		EnableNAT  bool     `json:"enable_nat"`
		OutIf      string   `json:"out_if"`
		DNS        []string `json:"dns"`
		USBMode    string   `json:"usb_mode"`
		WatchdogOn bool     `json:"watchdog_on"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	switch req.Action {
	case "prefer_lte":
		m := getModemStatus()
		gw, _ := m["bearer_gw"].(string)
		if gw != "" {
			_, _ = runCmd(3*time.Second, "ip", "route", "replace", "default", "via", gw, "dev", "wwan0", "metric", "50")
		}
	case "prefer_wifi":
		_, _ = runCmd(3*time.Second, "ip", "route", "del", "default", "dev", "wwan0", "metric", "50")
	case "toggle_nat":
		val := "0"
		if req.EnableNAT {
			val = "1"
		}
		_ = os.WriteFile("/proc/sys/net/ipv4/ip_forward", []byte(val), 0644)
		if req.EnableNAT {
			outIf := req.OutIf
			if outIf == "" {
				outIf = "wwan0"
			}
			_, _ = runCmd(3*time.Second, "iptables", "-t", "nat", "-A", "POSTROUTING", "-o", outIf, "-j", "MASQUERADE")
			_, _ = runCmd(3*time.Second, "nft", "add", "table", "ip", "uz801_nat")
			_, _ = runCmd(3*time.Second, "nft", "add", "chain", "ip", "uz801_nat", "postrouting", "{ type nat hook postrouting priority 100 ; }")
			_, _ = runCmd(3*time.Second, "nft", "add", "rule", "ip", "uz801_nat", "postrouting", "oifname", outIf, "masquerade")
		}
	case "set_dns":
		if len(req.DNS) > 0 {
			var lines []string
			for _, ip := range req.DNS {
				ip = strings.TrimSpace(ip)
				if ip != "" {
					lines = append(lines, "nameserver "+ip)
				}
			}
			if len(lines) > 0 {
				_ = os.WriteFile("/etc/resolv.conf", []byte(strings.Join(lines, "\n")+"\n"), 0644)
			}
		}
	case "set_usb":
		switch req.USBMode {
		case "ncm":
			_, _ = runCmd(8*time.Second, "/usr/sbin/usb-gadget", "enable_ncm")
		case "rndis":
			_, _ = runCmd(8*time.Second, "/usr/sbin/usb-gadget", "enable_rndis")
		case "otg_on":
			_, _ = runCmd(8*time.Second, "/usr/sbin/usb-gadget", "enable_otg")
		case "otg_off":
			_, _ = runCmd(8*time.Second, "/usr/sbin/usb-gadget", "disable_otg")
		}
	case "set_watchdog":
		watchdogMu.Lock()
		watchdogEnabled = req.WatchdogOn
		watchdogMu.Unlock()
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "routes": getRoutesAndNAT()})
}

func handleWiFiScan(w http.ResponseWriter, r *http.Request) {
	out, err := runCmd(10*time.Second, "nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY,CHAN", "dev", "wifi", "list", "--rescan", "yes")
	var networks []map[string]any
	if err == nil && out != "" {
		seen := map[string]bool{}
		for _, line := range strings.Split(out, "\n") {
			parts := strings.Split(line, ":")
			if len(parts) >= 5 {
				ssid := parts[1]
				if ssid == "" || seen[ssid] {
					continue
				}
				seen[ssid] = true
				sig, _ := strconv.Atoi(parts[2])
				networks = append(networks, map[string]any{
					"active":   parts[0] == "*",
					"ssid":     ssid,
					"signal":   sig,
					"security": parts[3],
					"channel":  parts[4],
				})
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"networks": networks})
}

func handleWiFiConnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req struct {
		Mode     string `json:"mode"` // sta | ap
		SSID     string `json:"ssid"`
		Password string `json:"password"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.SSID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "ssid required"})
		return
	}
	if req.Mode == "ap" {
		storeMu.Lock()
		appStore.HotspotConfig.SSID = req.SSID
		appStore.HotspotConfig.Password = req.Password
		appStore.HotspotConfig.Active = true
		cfg := appStore.HotspotConfig
		saveStoreLocked()
		storeMu.Unlock()
		out, err := startHotspotAP(cfg)
		writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out})
		return
	}
	args := []string{"dev", "wifi", "connect", req.SSID}
	if req.Password != "" {
		args = append(args, "password", req.Password)
	}
	out, err := runCmd(25*time.Second, "nmcli", args...)
	writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out})
}

func handleDiag(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req struct {
		Tool      string `json:"tool"`
		Target    string `json:"target"`
		Interface string `json:"interface"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.Target == "" {
		req.Target = "1.1.1.1"
	}
	var out string
	var err error
	switch req.Tool {
	case "public_ip":
		args := []string{"-sS", "--max-time", "8"}
		if req.Interface != "" {
			args = append(args, "--interface", req.Interface)
		}
		args = append(args, "http://ip-api.com/json")
		out, err = runCmd(10*time.Second, "curl", args...)
	case "route":
		out, err = runCmd(4*time.Second, "ip", "route", "show")
	default:
		args := []string{"-c", "4", "-W", "2"}
		if req.Interface != "" {
			args = append(args, "-I", req.Interface)
		}
		args = append(args, req.Target)
		out, err = runCmd(12*time.Second, "ping", args...)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out})
}

func handleExec(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req struct {
		Command string `json:"command"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if strings.TrimSpace(req.Command) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "empty command"})
		return
	}
	out, err := runCmd(15*time.Second, "sh", "-c", req.Command)
	writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out})
}

func handleSystemAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req struct {
		Action string `json:"action"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	switch req.Action {
	case "drop_caches":
		_, _ = runCmd(2*time.Second, "sync")
		_ = os.WriteFile("/proc/sys/vm/drop_caches", []byte("3"), 0644)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": "PageCache, dentries, and inodes cleared"})
	case "reboot":
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": "Rebooting device..."})
		go func() {
			time.Sleep(500 * time.Millisecond)
			_, _ = runCmd(5*time.Second, "reboot")
		}()
	case "reboot_bootloader":
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": "Rebooting to lk2nd Fastboot..."})
		go func() {
			time.Sleep(500 * time.Millisecond)
			_, _ = runCmd(5*time.Second, "systemctl", "reboot", "--reboot-argument=bootloader")
			_, _ = runCmd(5*time.Second, "reboot", "bootloader")
		}()
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "unknown action"})
	}
}

func handlePortalDesign(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		storeMu.Lock()
		p := appStore.PortalDesign
		storeMu.Unlock()
		writeJSON(w, http.StatusOK, p)
		return
	}
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	var req PortalDesign
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid body"})
		return
	}
	storeMu.Lock()
	appStore.PortalDesign = req
	saveStoreLocked()
	storeMu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "portal": req})
}

func handlePortalLogin(w http.ResponseWriter, r *http.Request) {
	remoteIP, _, _ := net.SplitHostPort(r.RemoteAddr)
	if remoteIP == "" {
		remoteIP = r.RemoteAddr
	}
	// Resolve MAC from discovered clients
	clients := discoverConnectedClients()
	clientMAC := ""
	for _, c := range clients {
		if c.IP == remoteIP {
			clientMAC = c.MAC
			break
		}
	}

	if r.Method == http.MethodGet {
		// Return current client's active voucher status + portal design
		storeMu.Lock()
		portalCfg := appStore.PortalDesign
		var activeVoucher *Voucher
		for _, v := range appStore.Vouchers {
			for _, m := range v.AssignedMACs {
				if clientMAC != "" && strings.EqualFold(m, clientMAC) {
					activeVoucher = v
					break
				}
			}
			for _, ip := range v.AssignedIPs {
				if ip == remoteIP {
					activeVoucher = v
					break
				}
			}
		}
		storeMu.Unlock()
		writeJSON(w, http.StatusOK, map[string]any{
			"client_ip":  remoteIP,
			"client_mac": clientMAC,
			"portal":     portalCfg,
			"voucher":    activeVoucher,
		})
		return
	}

	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Code) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "Masukkan kode voucher"})
		return
	}

	storeMu.Lock()

	code := strings.TrimSpace(req.Code)
	var found *Voucher
	for _, v := range appStore.Vouchers {
		if strings.EqualFold(v.Code, code) {
			found = v
			break
		}
	}
	if found == nil {
		storeMu.Unlock()
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "Kode voucher tidak valid atau tidak ditemukan"})
		return
	}
	if found.Status == "disabled" || found.Status == "expired" || found.Status == "exhausted" {
		storeMu.Unlock()
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "Status voucher ini: " + found.Status})
		return
	}

	if clientMAC != "" {
		already := false
		for _, m := range found.AssignedMACs {
			if strings.EqualFold(m, clientMAC) {
				already = true
				break
			}
		}
		if !already && found.MaxDevices > 0 && len(found.AssignedMACs) >= found.MaxDevices {
			storeMu.Unlock()
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": fmt.Sprintf("Voucher sudah mencapai batas maksimal %d perangkat", found.MaxDevices)})
			return
		}
		if !already {
			found.AssignedMACs = append(found.AssignedMACs, clientMAC)
		}
		delete(appStore.BlockedMACs, clientMAC)
	}
	if remoteIP != "" {
		alreadyIP := false
		for _, ip := range found.AssignedIPs {
			if ip == remoteIP {
				alreadyIP = true
				break
			}
		}
		if !alreadyIP {
			found.AssignedIPs = append(found.AssignedIPs, remoteIP)
		}
	}
	if found.ActivatedAt == 0 {
		nowUnix := time.Now().Unix()
		found.ActivatedAt = nowUnix
		if found.DurationMins > 0 {
			found.ExpiresAt = nowUnix + (found.DurationMins * 60)
		}
	}
	found.Status = "active"
	saveStoreLocked()
	storeMu.Unlock()

	// Synchronously update iptables & nftables QoS BEFORE returning response so phone CPD probe immediately succeeds!
	syncCaptiveFirewall()

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":         true,
		"client_ip":  remoteIP,
		"client_mac": clientMAC,
		"voucher":    found,
	})
}

func start4GWatchdog() {
	go func() {
		for {
			time.Sleep(45 * time.Second)
			watchdogMu.Lock()
			en := watchdogEnabled
			watchdogMu.Unlock()
			if !en {
				continue
			}
			_, err := runCmd(5*time.Second, "ping", "-I", "wwan0", "-c", "1", "-W", "3", "1.1.1.1")
			watchdogMu.Lock()
			if err == nil {
				watchdogLastCheck = time.Now().Format("15:04:05") + " (OK)"
				watchdogMu.Unlock()
				continue
			}
			watchdogLastCheck = time.Now().Format("15:04:05") + " (Reconnecting...)"
			watchdogRestarts++
			watchdogMu.Unlock()

			_, _ = runCmd(4*time.Second, "mmcli", "-m", "0", "--set-power-state-on")
			_, _ = runCmd(4*time.Second, "mmcli", "-m", "0", "-e")
			if _, err := runCmd(15*time.Second, "nmcli", "connection", "up", "lte"); err != nil {
				_, _ = runCmd(15*time.Second, "mmcli", "-m", "0", "--simple-connect=apn=byu,ip-type=ipv4")
			}
		}
	}()
}

func main() {
	_ = os.Setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	_ = os.Setenv("LC_ALL", "C")
	_ = os.Chdir("/")

	addr := flag.String("addr", "", "HTTP listen address (default: :80 with fallback to :8080)")
	flag.Parse()

	loadStore()
	sampleCPU()
	syncCaptiveFirewall()
	start4GWatchdog()
	startVoucherEnforcer()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", handleStatus)
	mux.HandleFunc("/api/clients", handleClientsAction)
	mux.HandleFunc("/api/vouchers", handleVouchers)
	mux.HandleFunc("/api/hotspot", handleHotspotConfig)
	mux.HandleFunc("/api/portal/design", handlePortalDesign)
	mux.HandleFunc("/api/portal/login", handlePortalLogin)
	mux.HandleFunc("/api/sms", handleSMSList)
	mux.HandleFunc("/api/sms/send", handleSMSSend)
	mux.HandleFunc("/api/sms/delete", handleSMSDelete)
	mux.HandleFunc("/api/ussd", handleUSSD)
	mux.HandleFunc("/api/modem/action", handleModemAction)
	mux.HandleFunc("/api/leds", handleLEDControl)
	mux.HandleFunc("/api/cpu", handleCPUControl)
	mux.HandleFunc("/api/network", handleNetworkControl)
	mux.HandleFunc("/api/wifi/scan", handleWiFiScan)
	mux.HandleFunc("/api/wifi/connect", handleWiFiConnect)
	mux.HandleFunc("/api/diag", handleDiag)
	mux.HandleFunc("/api/exec", handleExec)
	mux.HandleFunc("/api/system", handleSystemAction)

	subFS, err := fs.Sub(staticEmbed, "static")
	if err != nil {
		log.Fatal(err)
	}
	fileServer := http.FileServer(http.FS(subFS))
	mux.HandleFunc("/portal", func(w http.ResponseWriter, r *http.Request) {
		b, err := staticEmbed.ReadFile("static/portal.html")
		if err != nil {
			http.Error(w, "portal not found", 404)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(b)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		remoteIP, _, _ := net.SplitHostPort(r.RemoteAddr)
		path := r.URL.Path
		host := strings.Split(r.Host, ":")[0]

		// Handle OS Captive Portal Detection (Android, iOS/macOS, Windows, Firefox)
		isCPD := path == "/generate_204" || path == "/gen_204" ||
			path == "/hotspot-detect.html" || path == "/library/test/success.html" ||
			path == "/connecttest.txt" || path == "/ncsi.txt" || path == "/success.txt" ||
			(host != "" && host != "192.168.43.1" && host != "192.168.42.1" && host != "127.0.0.1" && host != "localhost" && !strings.HasPrefix(host, "192.168.1."))

		if strings.HasPrefix(remoteIP, "192.168.43.") {
			auth := isClientAuthorized(remoteIP)
			if !auth {
				http.Redirect(w, r, "http://192.168.43.1/portal", http.StatusFound)
				return
			}
			if isCPD {
				if strings.Contains(path, "204") {
					w.WriteHeader(http.StatusNoContent)
					return
				}
				if strings.Contains(path, "hotspot-detect") || strings.Contains(path, "success.html") {
					w.Header().Set("Content-Type", "text/html")
					_, _ = w.Write([]byte("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"))
					return
				}
				w.Header().Set("Content-Type", "text/plain")
				_, _ = w.Write([]byte("Microsoft Connect Test"))
				return
			}
		}
		fileServer.ServeHTTP(w, r)
	})

	var ln net.Listener
	if *addr != "" {
		ln, err = net.Listen("tcp", *addr)
		if err != nil {
			log.Fatal(err)
		}
	} else {
		ln, err = net.Listen("tcp", ":80")
		if err != nil {
			ln, err = net.Listen("tcp", ":8080")
			if err != nil {
				log.Fatal(err)
			}
		}
	}
	log.Printf("[+] UZ801 Modem Manager listening on %s", ln.Addr().String())
	log.Fatal(http.Serve(ln, mux))
}
