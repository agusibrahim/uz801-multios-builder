package main

import (
	"bytes"
	"context"
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

	watchdogMu      sync.Mutex
	watchdogEnabled = true
	watchdogLastCheck string
	watchdogRestarts  int
)

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
	out, _ := runCmd(2*time.Second, "df", "-B1", "/")
	lines := strings.Split(out, "\n")
	if len(lines) >= 2 {
		f := strings.Fields(lines[len(lines)-1])
		if len(f) >= 5 {
			tot, _ := strconv.ParseUint(f[1], 10, 64)
			used, _ := strconv.ParseUint(f[2], 10, 64)
			avail, _ := strconv.ParseUint(f[3], 10, 64)
			return map[string]any{
				"total_bytes": tot,
				"used_bytes":  used,
				"avail_bytes": avail,
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
	for _, path := range []string{"/run/dnsmasq-usb0.leases", "/tmp/dhcp.leases", "/var/lib/misc/dnsmasq.leases"} {
		raw := readFileTrim(path)
		if raw == "" {
			continue
		}
		for _, line := range strings.Split(raw, "\n") {
			f := strings.Fields(line)
			if len(f) >= 4 {
				leases = append(leases, map[string]string{
					"expires":  f[0],
					"mac":      f[1],
					"ip":       f[2],
					"hostname": f[3],
				})
			}
		}
		break
	}
	return leases
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
	prefix := key + " :"
	for _, line := range strings.Split(kvOut, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			val := strings.TrimSpace(strings.TrimPrefix(line, prefix))
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
	bearerPath := extractKV(out, "modem.generic.bearers.value[1]")

	// Detailed LTE RF metrics
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
	bearerGW := ""
	bearerDNS := ""
	bearerAPN := ""
	bearerUptime := ""
	if bearerPath != "" {
		bOut, err := runCmd(2*time.Second, "mmcli", "-b", bearerPath, "-K")
		if err == nil {
			bearerAPN = extractKV(bOut, "bearer.properties.apn")
			bearerIP = extractKV(bOut, "bearer.ipv4-config.address")
			bearerGW = extractKV(bOut, "bearer.ipv4-config.gateway")
			bearerDNS = extractKV(bOut, "bearer.ipv4-config.dns.value[1]")
			bearerUptime = extractKV(bOut, "bearer.stats.duration")
		}
	}

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
	})
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
		out, err := runCmd(20*time.Second, "mmcli", "-m", "0", "--3gpp-ussd-respond="+req.Code)
		writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out})
	default:
		_, _ = runCmd(3*time.Second, "mmcli", "-m", "0", "--3gpp-ussd-cancel")
		out, err := runCmd(20*time.Second, "mmcli", "-m", "0", "--3gpp-ussd-initiate="+req.Code)
		writeJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "output": out})
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
		out, err = runCmd(20*time.Second, "mmcli", "-m", "0", fmt.Sprintf("--simple-connect=apn=%s,ip-type=%s", req.APN, req.IPType))
		_, _ = runCmd(10*time.Second, "nmcli", "connection", "up", "lte")
	case "disconnect":
		_, _ = runCmd(5*time.Second, "nmcli", "connection", "down", "lte")
		out, err = runCmd(10*time.Second, "mmcli", "-m", "0", "--simple-disconnect")
	case "reset":
		out, err = runCmd(10*time.Second, "mmcli", "-m", "0", "--reset")
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
		Action     string   `json:"action"` // prefer_lte | prefer_wifi | toggle_nat | set_dns | set_usb | set_watchdog
		EnableNAT  bool     `json:"enable_nat"`
		OutIf      string   `json:"out_if"`
		DNS        []string `json:"dns"`
		USBMode    string   `json:"usb_mode"` // ncm | rndis | otg_on | otg_off
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
		_ = os.WriteFile("/proc/sys/net/ipv4/ip_forward", []byte("1"), 0644)
		_, _ = runCmd(3*time.Second, "iptables", "-t", "nat", "-A", "POSTROUTING", "-o", "wwan0", "-j", "MASQUERADE")
		out, err := runCmd(20*time.Second, "nmcli", "dev", "wifi", "hotspot", "ifname", "wlan0", "ssid", req.SSID, "password", req.Password)
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
			_, _ = runCmd(10*time.Second, "nmcli", "connection", "up", "lte")
			_, _ = runCmd(15*time.Second, "mmcli", "-m", "0", "--simple-connect=apn=byu,ip-type=ipv4")
		}
	}()
}

func main() {
	addr := flag.String("addr", "", "HTTP listen address (default: :80 with fallback to :8080)")
	flag.Parse()

	sampleCPU()
	start4GWatchdog()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", handleStatus)
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
	mux.Handle("/", http.FileServer(http.FS(subFS)))

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
