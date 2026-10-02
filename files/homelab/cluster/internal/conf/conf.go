// Package conf reads /etc/bluefin/homelab.conf, the homelab template's
// settings file, in the subset of systemd EnvironmentFile syntax the
// template writes: KEY=value lines, '#' and ';' comments, optional single
// or double quotes around the value.
package conf

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const DefaultPath = "/etc/bluefin/homelab.conf"

// Roles a homelab node can have (HOMELAB_ROLE). An unset role is a
// single-node homelab: no discovery, no join service.
const (
	RoleControlPlane = "control-plane"
	RoleNode         = "node"
)

type Config map[string]string

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(data), nil
}

// Parse parses KEY=value lines; malformed lines are ignored, as systemd
// does.
func Parse(data []byte) Config {
	c := Config{}
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		key, value, ok := parseLine(sc.Text())
		if ok {
			c[key] = value
		}
	}
	return c
}

func parseLine(line string) (key, value string, ok bool) {
	line = strings.TrimSpace(line)
	if line == "" || line[0] == '#' || line[0] == ';' {
		return "", "", false
	}
	key, value, ok = strings.Cut(line, "=")
	if !ok {
		return "", "", false
	}
	key = strings.TrimSpace(key)
	if strings.HasPrefix(key, "export ") {
		key = strings.TrimSpace(strings.TrimPrefix(key, "export "))
	}
	if key == "" || strings.ContainsAny(key, " \t") {
		return "", "", false
	}
	value = strings.TrimSpace(value)
	if len(value) >= 2 && (value[0] == '"' || value[0] == '\'') && value[len(value)-1] == value[0] {
		value = value[1 : len(value)-1]
	}
	return key, value, true
}

func (c Config) Role() string { return c["HOMELAB_ROLE"] }

func (c Config) Get(key, def string) string {
	if v := c[key]; v != "" {
		return v
	}
	return def
}

// RemoveKey rewrites path without the lines that set key, keeping the
// file's mode. It is how a node forgets the join passphrase once joined.
func RemoveKey(path, key string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	var out bytes.Buffer
	removed := false
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		if k, _, ok := parseLine(sc.Text()); ok && k == key {
			removed = true
			continue
		}
		out.WriteString(sc.Text())
		out.WriteByte('\n')
	}
	if !removed {
		return nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".homelab.conf.")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(info.Mode().Perm()); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(out.Bytes()); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("replacing %s: %w", path, err)
	}
	return nil
}
