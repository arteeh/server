// Package discover finds the cluster's join service: DNS-SD over mDNS
// through systemd-resolved's varlink API (io.systemd.Resolve
// BrowseServices + ResolveService; no Avahi), or a manually configured
// host[:port].
package discover

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	ResolveSocket = "/run/systemd/resolve/io.systemd.Resolve"
	ServiceType   = "_bluefin-cluster._tcp"
	DefaultPort   = 6447
)

// Candidate is one way to reach a join service.
type Candidate struct {
	Name  string // DNS-SD instance name or the configured host
	Addrs []netip.AddrPort
	TXT   map[string]string
}

type varlinkReply struct {
	Parameters json.RawMessage `json:"parameters"`
	Continues  bool            `json:"continues"`
	Error      string          `json:"error"`
}

// call sends one varlink method call and hands every reply to fn until fn
// returns false, the server stops continuing, or ctx ends.
func call(ctx context.Context, socket, method string, params any, more bool, fn func(json.RawMessage) bool) error {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", socket)
	if err != nil {
		return err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()

	req := map[string]any{"method": method, "parameters": params}
	if more {
		req["more"] = true
	}
	msg, err := json.Marshal(req)
	if err != nil {
		return err
	}
	if _, err := conn.Write(append(msg, 0)); err != nil {
		return err
	}
	r := bufio.NewReader(conn)
	for {
		raw, err := r.ReadBytes(0)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
		var reply varlinkReply
		if err := json.Unmarshal(raw[:len(raw)-1], &reply); err != nil {
			return fmt.Errorf("%s: %w", method, err)
		}
		if reply.Error != "" {
			return fmt.Errorf("%s: %s", method, reply.Error)
		}
		if !fn(reply.Parameters) || !reply.Continues {
			return nil
		}
	}
}

type browsed struct {
	UpdateFlag string `json:"updateFlag"`
	Family     int    `json:"family"`
	Name       string `json:"name"`
	Type       string `json:"type"`
	Domain     string `json:"domain"`
	Ifindex    int    `json:"ifindex"`
}

// sdResolvedMDNS is SD_RESOLVED_MDNS_IPV4|SD_RESOLVED_MDNS_IPV6: browsing
// is mDNS continuous querying only.
const sdResolvedMDNS = 1<<3 | 1<<4

// Browse collects the instances of ServiceType seen on one link during
// window. resolved browses per link: ifindex selects its mDNS scope.
func Browse(ctx context.Context, socket string, ifindex int, window time.Duration) ([]browsed, error) {
	ctx, cancel := context.WithTimeout(ctx, window)
	defer cancel()
	seen := map[string]browsed{}
	err := call(ctx, socket, "io.systemd.Resolve.BrowseServices",
		map[string]any{"domain": "local", "type": ServiceType, "ifindex": ifindex, "flags": sdResolvedMDNS}, true,
		func(p json.RawMessage) bool {
			var out struct {
				Services []browsed `json:"browserServiceData"`
			}
			if json.Unmarshal(p, &out) != nil {
				return true
			}
			for _, s := range out.Services {
				key := fmt.Sprintf("%s|%d", s.Name, s.Ifindex)
				if s.UpdateFlag == "removed" {
					delete(seen, key)
				} else if s.Name != "" {
					seen[key] = s
				}
			}
			return true
		})
	if err != nil && !errors.Is(err, context.DeadlineExceeded) {
		return nil, err
	}
	list := make([]browsed, 0, len(seen))
	for _, s := range seen {
		list = append(list, s)
	}
	return list, nil
}

type resolvedAddress struct {
	Ifindex int   `json:"ifindex"`
	Family  int   `json:"family"`
	Address []int `json:"address"`
}

type resolvedService struct {
	Services []struct {
		Port      int               `json:"port"`
		Hostname  string            `json:"hostname"`
		Addresses []resolvedAddress `json:"addresses"`
	} `json:"services"`
	TXT []string `json:"txt"`
}

// Resolve turns a browsed instance into addresses and its TXT record.
func Resolve(ctx context.Context, socket string, s browsed) (Candidate, error) {
	var out resolvedService
	params := map[string]any{"name": s.Name, "type": s.Type, "domain": s.Domain}
	if s.Ifindex > 0 {
		params["ifindex"] = s.Ifindex
	}
	err := call(ctx, socket, "io.systemd.Resolve.ResolveService", params, false, func(p json.RawMessage) bool {
		_ = json.Unmarshal(p, &out)
		return false
	})
	if err != nil {
		return Candidate{}, err
	}
	c := Candidate{Name: s.Name, TXT: ParseTXT(out.TXT)}
	for _, svc := range out.Services {
		for _, a := range svc.Addresses {
			addr, ok := toAddr(a)
			if !ok || addr.IsLinkLocalUnicast() {
				continue
			}
			c.Addrs = append(c.Addrs, netip.AddrPortFrom(addr, uint16(svc.Port)))
		}
	}
	sortAddrs(c.Addrs)
	if len(c.Addrs) == 0 {
		return Candidate{}, fmt.Errorf("%s: no addresses", s.Name)
	}
	return c, nil
}

// sortAddrs puts IPv4 first: a home LAN reliably routes it.
func sortAddrs(a []netip.AddrPort) {
	sort.SliceStable(a, func(i, j int) bool { return a[i].Addr().Is4() && !a[j].Addr().Is4() })
}

func toAddr(a resolvedAddress) (netip.Addr, bool) {
	b := make([]byte, len(a.Address))
	for i, v := range a.Address {
		if v < 0 || v > 255 {
			return netip.Addr{}, false
		}
		b[i] = byte(v)
	}
	addr, ok := netip.AddrFromSlice(b)
	if !ok {
		return netip.Addr{}, false
	}
	addr = addr.Unmap()
	if addr.Is6() && addr.IsLinkLocalUnicast() && a.Ifindex > 0 {
		addr = addr.WithZone(strconv.Itoa(a.Ifindex))
	}
	return addr, true
}

// ParseTXT turns "key=value" TXT strings into a map.
func ParseTXT(items []string) map[string]string {
	m := map[string]string{}
	for _, it := range items {
		k, v, _ := strings.Cut(it, "=")
		m[k] = v
	}
	return m
}

// Links lists the up, multicast-capable, non-loopback interfaces.
func Links() []int {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []int
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp != 0 && ifc.Flags&net.FlagMulticast != 0 && ifc.Flags&net.FlagLoopback == 0 {
			out = append(out, ifc.Index)
		}
	}
	return out
}

// MDNS browses every link in links at once and resolves each join service
// found.
func MDNS(ctx context.Context, socket string, links []int, window time.Duration) ([]Candidate, error) {
	var (
		mu    sync.Mutex
		wg    sync.WaitGroup
		found []browsed
		errs  []error
	)
	for _, idx := range links {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got, err := Browse(ctx, socket, idx, window)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errs = append(errs, fmt.Errorf("link %d: %w", idx, err))
			}
			found = append(found, got...)
		}()
	}
	wg.Wait()
	if len(found) == 0 && len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	errs = nil
	var out []Candidate
	for _, s := range found {
		rctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		c, err := Resolve(rctx, socket, s)
		cancel()
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if c.TXT["v"] != "1" {
			continue
		}
		out = append(out, c)
	}
	if len(out) == 0 && len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	return out, nil
}

// Manual resolves HOMELAB_CONTROL_PLANE (host, host:port, [v6]:port)
// through the system resolver, which answers <name>.local over mDNS via
// nss-resolve.
func Manual(ctx context.Context, hostport string) (Candidate, error) {
	host, port := hostport, strconv.Itoa(DefaultPort)
	if h, p, err := net.SplitHostPort(hostport); err == nil {
		host, port = h, p
	}
	pn, err := strconv.ParseUint(port, 10, 16)
	if err != nil || pn == 0 {
		return Candidate{}, fmt.Errorf("HOMELAB_CONTROL_PLANE=%q: bad port", hostport)
	}
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return Candidate{}, err
	}
	c := Candidate{Name: host}
	for _, ip := range ips {
		c.Addrs = append(c.Addrs, netip.AddrPortFrom(ip.Unmap(), uint16(pn)))
	}
	sortAddrs(c.Addrs)
	return c, nil
}

// ResolveHost resolves name (e.g. <cp>.local) through resolved, IPv4
// preferred. Statically linked Go programs (kubelet, kubectl) skip
// nss-resolve, so the result is pinned in /etc/hosts for them.
func ResolveHost(ctx context.Context, socket, name string) (netip.Addr, error) {
	var errs []error
	for _, family := range []int{afInet, afInet6} {
		var out struct {
			Addresses []resolvedAddress `json:"addresses"`
		}
		err := call(ctx, socket, "io.systemd.Resolve.ResolveHostname", map[string]any{"name": name, "family": family}, false, func(p json.RawMessage) bool {
			_ = json.Unmarshal(p, &out)
			return false
		})
		if err != nil {
			errs = append(errs, err)
			continue
		}
		for _, a := range out.Addresses {
			if addr, ok := toAddr(a); ok && !addr.IsLinkLocalUnicast() {
				return addr, nil
			}
		}
	}
	return netip.Addr{}, fmt.Errorf("%s: no usable address: %w", name, errors.Join(errs...))
}

const (
	afInet  = 2
	afInet6 = 10
)
