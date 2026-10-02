package discover

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeResolved answers BrowseServices with one service and ResolveService
// with an address and TXT, like systemd-resolved's varlink interface.
func fakeResolved(t *testing.T) string {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "io.systemd.Resolve")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				raw, err := bufio.NewReader(c).ReadBytes(0)
				if err != nil {
					return
				}
				var req struct {
					Method string         `json:"method"`
					Params map[string]any `json:"parameters"`
					More   bool           `json:"more"`
				}
				_ = json.Unmarshal(raw[:len(raw)-1], &req)
				send := func(v any) { b, _ := json.Marshal(v); _, _ = c.Write(append(b, 0)) }
				switch req.Method {
				case "io.systemd.Resolve.BrowseServices":
					// resolved needs the link and the mDNS flags.
					if !req.More || req.Params["type"] != ServiceType || req.Params["ifindex"] != float64(2) || req.Params["flags"] != float64(24) {
						send(map[string]any{"error": "org.varlink.service.InvalidParameter"})
						return
					}
					send(map[string]any{"continues": true, "parameters": map[string]any{"browserServiceData": []any{
						map[string]any{"updateFlag": "added", "family": 2, "name": "cp1", "type": ServiceType, "domain": "local", "ifindex": 2},
						map[string]any{"updateFlag": "added", "family": 2, "name": "old", "type": ServiceType, "domain": "local", "ifindex": 2},
					}}})
					send(map[string]any{"continues": true, "parameters": map[string]any{"browserServiceData": []any{
						map[string]any{"updateFlag": "removed", "family": 2, "name": "old", "type": ServiceType, "domain": "local", "ifindex": 2},
					}}})
					time.Sleep(time.Hour)
				case "io.systemd.Resolve.ResolveHostname":
					addr := []int{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
					if req.Params["family"] == float64(2) {
						addr = []int{192, 0, 2, 10}
					}
					send(map[string]any{"parameters": map[string]any{"addresses": []any{map[string]any{"ifindex": 2, "family": req.Params["family"], "address": addr}}, "name": "cp1.local", "flags": 0}})
				case "io.systemd.Resolve.ResolveService":
					send(map[string]any{"parameters": map[string]any{
						"services": []any{map[string]any{"priority": 0, "weight": 0, "port": 6447, "hostname": "cp1.local",
							"addresses": []any{
								map[string]any{"ifindex": 2, "family": 10, "address": []int{0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}},
								map[string]any{"ifindex": 2, "family": 10, "address": []int{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}},
								map[string]any{"ifindex": 2, "family": 2, "address": []int{192, 0, 2, 10}}}}},
						"txt":       []string{"v=1", "cluster=lab", "runtime=kubeadm"},
						"canonical": map[string]any{"name": "cp1", "type": ServiceType, "domain": "local"},
						"flags":     0,
					}})
				}
			}(c)
		}
	}()
	return sock
}

func TestMDNSBrowseAndResolve(t *testing.T) {
	sock := fakeResolved(t)
	got, err := MDNS(context.Background(), sock, []int{2}, 300*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Name != "cp1" || len(got[0].Addrs) != 2 || got[0].Addrs[0].String() != "192.0.2.10:6447" ||
		got[0].TXT["cluster"] != "lab" || got[0].TXT["runtime"] != "kubeadm" {
		t.Fatalf("got %+v", got)
	}
}

func TestManual(t *testing.T) {
	c, err := Manual(context.Background(), "127.0.0.1")
	if err != nil || c.Addrs[0].String() != "127.0.0.1:6447" {
		t.Fatal(c, err)
	}
	c, err = Manual(context.Background(), "[::1]:7000")
	if err != nil || c.Addrs[0].String() != "[::1]:7000" {
		t.Fatal(c, err)
	}
	if _, err := Manual(context.Background(), "host:0"); err == nil || !strings.Contains(err.Error(), "bad port") {
		t.Fatal(err)
	}
}

func TestBrowseWithoutTheLinkIsRefused(t *testing.T) {
	sock := fakeResolved(t)
	if _, err := MDNS(context.Background(), sock, []int{7}, 300*time.Millisecond); err == nil {
		t.Fatal("a browse on the wrong link must not find the service")
	}
}

func TestResolveHostPrefersIPv4(t *testing.T) {
	sock := fakeResolved(t)
	addr, err := ResolveHost(context.Background(), sock, "cp1.local")
	if err != nil || addr.String() != "192.0.2.10" {
		t.Fatal(addr, err)
	}
}
