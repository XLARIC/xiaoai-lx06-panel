package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	_ "time/tzdata"
)

//go:embed web/*
var assets embed.FS

const noTarget = "-"
const locationFile = "/data/location/location.conf"
const audioDir = "/data/lx06-lg-native"

var macPattern = regexp.MustCompile(`^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$`)
var zonePattern = regexp.MustCompile(`^[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*$`)
var devicePattern = regexp.MustCompile(`(?m)^Device ((?:[0-9A-F]{2}:){5}[0-9A-F]{2}) ([^\r\n]+)`)
var terminalCodes = regexp.MustCompile("\\x1b\\[[0-9;?]*[A-Za-z]")

type position struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	TimeZone  string  `json:"timeZone"`
}

type audio struct {
	Mode   string `json:"mode"`
	Target string `json:"target"`
	Delay  int    `json:"delay"`
}

type device struct {
	MAC  string `json:"mac"`
	Name string `json:"name"`
}

type panel struct {
	settings string
	password [32]byte
	actions  sync.Mutex
	demo     bool
}

func (a audio) valid() bool {
	validTarget := macPattern.MatchString(a.Target) || (a.Mode == "receive" && a.Target == noTarget)
	return (a.Mode == "output" || a.Mode == "receive") && validTarget && a.Delay >= 0 && a.Delay <= 750
}

func loadAudio(path string) (audio, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return audio{"receive", noTarget, 320}, nil
	}
	if err != nil {
		return audio{}, err
	}
	f := strings.Fields(string(b))
	if len(f) != 3 {
		return audio{}, errors.New("invalid audio configuration")
	}
	d, err := strconv.Atoi(f[2])
	a := audio{f[0], f[1], d}
	if err != nil || !a.valid() {
		return audio{}, errors.New("invalid audio configuration")
	}
	return a, nil
}

func loadLocation() (position, error) {
	b, err := os.ReadFile(locationFile)
	if err != nil {
		return position{}, err
	}
	var p position
	for _, line := range strings.Split(string(b), "\n") {
		key, val, _ := strings.Cut(line, "=")
		switch key {
		case "latitude":
			p.Latitude, err = strconv.ParseFloat(val, 64)
		case "longitude":
			p.Longitude, err = strconv.ParseFloat(val, 64)
		case "time_zone":
			p.TimeZone = val
		}
		if err != nil {
			return position{}, err
		}
	}
	return p, nil
}

func writeTemp(dir, pattern, value string) (string, error) {
	f, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return "", err
	}
	name := f.Name()
	_, writeErr := f.WriteString(value)
	closeErr := f.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		os.Remove(name)
		return "", err
	}
	return name, nil
}

func writeAudio(path string, a audio) error {
	name, err := writeTemp(audioDir, ".audio-*.conf", fmt.Sprintf("%s %s %d\n", a.Mode, a.Target, a.Delay))
	if err != nil {
		return err
	}
	defer os.Remove(name)
	return os.Rename(name, path)
}

func command(ctx context.Context, timeout time.Duration, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = time.Second
	return cmd.CombinedOutput()
}

type btStep struct {
	line  string
	pause time.Duration
}

func bluetooth(ctx context.Context, steps ...btStep) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 26*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/bluetoothctl")
	cmd.WaitDelay = time.Second
	reader, writer := io.Pipe()
	cmd.Stdin = reader
	defer reader.Close()
	go func() {
		defer writer.Close()
		for _, step := range steps {
			select {
			case <-time.After(step.pause):
			case <-ctx.Done():
				return
			}
			if _, err := fmt.Fprintln(writer, step.line); err != nil {
				return
			}
		}
	}()
	out, err := cmd.CombinedOutput()
	return terminalCodes.ReplaceAllString(string(out), ""), err
}

func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(value)
}

func reject(w http.ResponseWriter, status int, message string) {
	respond(w, status, map[string]string{"error": message})
}

func decode(w http.ResponseWriter, r *http.Request, value any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(value) != nil || d.Decode(new(any)) != io.EOF {
		reject(w, 400, "请检查输入格式")
		return false
	}
	return true
}

func (p *panel) state(w http.ResponseWriter, r *http.Request) {
	var pos *position
	var a audio
	var linked bool
	if p.demo {
		a = audio{"receive", noTarget, 320}
	} else {
		saved, err := loadLocation()
		if err == nil {
			pos = &saved
		} else if !errors.Is(err, os.ErrNotExist) {
			reject(w, 503, "无法读取当前位置")
			return
		}
		a, err = loadAudio(p.settings)
		if err != nil {
			reject(w, 503, "无法读取蓝牙配置")
			return
		}
		out, _ := command(r.Context(), 2*time.Second, "hcitool", "con")
		_, ready := os.Stat("/tmp/lx06-lg-native/ready")
		linked = a.Mode == "output" && ready == nil && strings.Contains(string(out), a.Target)
	}
	respond(w, 200, map[string]any{"position": pos, "audio": a, "linked": linked})
}

func (p *panel) location(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Latitude  *float64 `json:"latitude"`
		Longitude *float64 `json:"longitude"`
		TimeZone  string   `json:"timeZone"`
		Consent   bool     `json:"consent"`
	}
	if !decode(w, r, &input) {
		return
	}
	if input.Latitude == nil || input.Longitude == nil {
		reject(w, 400, "请输入经纬度")
		return
	}
	pos := position{*input.Latitude, *input.Longitude, input.TimeZone}
	_, zoneErr := time.LoadLocation(pos.TimeZone)
	if !input.Consent || math.IsNaN(pos.Latitude) || math.IsNaN(pos.Longitude) ||
		pos.Latitude < -90 || pos.Latitude > 90 || pos.Longitude < -180 || pos.Longitude > 180 ||
		len(pos.TimeZone) > 127 || !zonePattern.MatchString(pos.TimeZone) || pos.TimeZone == "Local" || zoneErr != nil {
		reject(w, 400, "请输入有效坐标和时区，并确认提交")
		return
	}
	previous, err := loadLocation()
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		reject(w, 503, "无法读取当前位置")
		return
	}
	if err != nil || previous != pos {
		path, err := writeTemp("/tmp", "native-location-*.conf", fmt.Sprintf("latitude=%.7f\nlongitude=%.7f\ntime_zone=%s\n", pos.Latitude, pos.Longitude, pos.TimeZone))
		if err == nil {
			defer os.Remove(path)
			_, err = command(context.Background(), 35*time.Second, "/bin/sh", "/data/location/update.sh", path)
		}
		if err != nil {
			reject(w, 503, "位置保存失败，请重新读取当前设置")
			return
		}
	}
	respond(w, 200, map[string]string{"message": "位置已保存。可以问小爱现在几点和今天天气。"})
}

func devicesFrom(out string) []device {
	result := make([]device, 0)
	seen := make(map[string]bool)
	for _, match := range devicePattern.FindAllStringSubmatch(out, 64) {
		if !seen[match[1]] {
			seen[match[1]] = true
			result = append(result, device{match[1], strings.TrimSpace(match[2])})
		}
	}
	return result
}

func (p *panel) devices(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Scan bool `json:"scan"`
	}
	if !decode(w, r, &input) {
		return
	}
	steps := []btStep{{"paired-devices", time.Second}}
	if input.Scan {
		steps = []btStep{{"set-scan-filter-transport bredr", time.Second}, {"scan on", 0}, {"scan off", 6 * time.Second}, {"devices", time.Second}}
	}
	steps = append(steps, btStep{"quit", 250 * time.Millisecond})
	out, err := bluetooth(r.Context(), steps...)
	if err != nil {
		reject(w, 503, "无法读取蓝牙设备，请稍后重试")
		return
	}
	respond(w, 200, map[string]any{"devices": devicesFrom(out)})
}

func (p *panel) setAudio(w http.ResponseWriter, r *http.Request) {
	var a audio
	if !decode(w, r, &a) {
		return
	}
	if !a.valid() {
		reject(w, 400, "请选择蓝牙模式和有效的同步延迟")
		return
	}
	old, err := loadAudio(p.settings)
	if err != nil {
		reject(w, 503, "无法读取蓝牙配置")
		return
	}
	if a.Mode == "output" {
		info, err := bluetooth(r.Context(), btStep{"info " + a.Target, time.Second}, btStep{"quit", 300 * time.Millisecond})
		if err == nil && !strings.Contains(info, "Paired: yes") {
			info, err = bluetooth(r.Context(), btStep{"agent NoInputNoOutput", time.Second}, btStep{"pair " + a.Target, 300 * time.Millisecond}, btStep{"info " + a.Target, 9 * time.Second}, btStep{"quit", 500 * time.Millisecond})
		}
		if err != nil || !strings.Contains(info, "Paired: yes") ||
			!strings.Contains(strings.ToLower(info), "0000110b-0000-1000-8000-00805f9b34fb") {
			reject(w, 409, "没有配对到可接收音乐的音箱。请让音箱进入配对模式，再扫描。")
			return
		}
	}
	if old != a {
		err = writeAudio(p.settings, a)
		if err == nil && (old.Mode != a.Mode || (a.Mode == "output" && old.Delay != a.Delay)) {
			_, err = command(context.Background(), 20*time.Second, audioDir+"/activate.sh")
			if err != nil {
				writeAudio(p.settings, old)
				command(context.Background(), 20*time.Second, audioDir+"/activate.sh")
			}
		}
		if err != nil {
			reject(w, 503, "蓝牙设置保存失败，请重新读取当前设置")
			return
		}
	}
	respond(w, 200, map[string]string{"message": "蓝牙设置已保存，连接状态可能需要十几秒更新。"})
}

func (p *panel) handler() http.Handler {
	mux := http.NewServeMux()
	site, _ := fs.Sub(assets, "web")
	files := http.FileServer(http.FS(site))
	mux.Handle("GET /{$}", files)
	mux.Handle("GET /panel.js", files)
	mux.Handle("GET /panel.css", files)
	mux.HandleFunc("GET /api/state", p.state)
	for path, action := range map[string]http.HandlerFunc{
		"/api/location": p.location, "/api/devices": p.devices, "/api/audio": p.setAudio,
	} {
		mux.HandleFunc("POST "+path, func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("X-LX06-Panel") != "1" || r.Header.Get("Content-Type") != "application/json" {
				reject(w, 403, "请从音箱管理页面提交")
				return
			}
			if p.demo {
				reject(w, 503, "这是本地预览")
				return
			}
			if !p.actions.TryLock() {
				reject(w, 409, "小爱正在应用另一项操作，请稍后重试")
				return
			}
			defer p.actions.Unlock()
			action(w, r)
		})
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		local := r.Context().Value(http.LocalAddrContextKey).(net.Addr)
		if r.Host != local.String() {
			http.Error(w, "Open this page using the speaker IP address.", 403)
			return
		}
		user, pass, ok := r.BasicAuth()
		sum := sha256.Sum256([]byte(pass))
		if !ok || user != "admin" || subtle.ConstantTimeCompare(sum[:], p.password[:]) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="XiaoAi LX06"`)
			http.Error(w, "Sign in to manage this speaker.", 401)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

type limitedListener struct {
	net.Listener
	slots chan struct{}
}

type countedConn struct {
	net.Conn
	once sync.Once
	free func()
}

func (c *countedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.free)
	return err
}

func (l limitedListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		select {
		case l.slots <- struct{}{}:
			return &countedConn{Conn: c, free: func() { <-l.slots }}, nil
		default:
			c.Close()
		}
	}
}

func main() {
	address := flag.String("listen", "", "IPv4 address and port")
	subnet := flag.String("subnet", "", "trusted local IPv4 subnet")
	passwordFile := flag.String("password-file", "/data/lx06-panel/password", "file with admin password")
	demo := flag.Bool("demo", false, "read-only local preview")
	flag.Parse()
	addr, err := net.ResolveTCPAddr("tcp4", *address)
	if err != nil || addr.IP.To4() == nil || (!*demo && !addr.IP.IsPrivate()) || (*demo && !addr.IP.IsLoopback()) {
		log.Fatal("invalid local listen address")
	}
	_, network, err := net.ParseCIDR(*subnet)
	if err != nil || !network.Contains(addr.IP) {
		log.Fatal("invalid local subnet")
	}
	password, err := os.ReadFile(*passwordFile)
	if err != nil || len(strings.TrimSpace(string(password))) < 20 {
		log.Fatal("missing admin password")
	}
	p := &panel{settings: audioDir + "/audio.conf", password: sha256.Sum256([]byte(strings.TrimSpace(string(password)))), demo: *demo}
	l, err := net.ListenTCP("tcp4", addr)
	if err != nil {
		log.Fatal(err)
	}
	handler := p.handler()
	s := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			host, _, err := net.SplitHostPort(r.RemoteAddr)
			if err != nil || !network.Contains(net.ParseIP(host)) {
				http.Error(w, "Local Wi-Fi only.", 403)
				return
			}
			handler.ServeHTTP(w, r)
		}),
		ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 5 * time.Second,
		WriteTimeout: 65 * time.Second, IdleTimeout: 3 * time.Second, MaxHeaderBytes: 4096,
	}
	if *demo {
		log.Printf("Preview listening on %s", addr)
	}
	if err := s.Serve(limitedListener{l, make(chan struct{}, 8)}); !errors.Is(err, net.ErrClosed) && !errors.Is(err, syscall.EINTR) {
		log.Fatal(err)
	}
}
