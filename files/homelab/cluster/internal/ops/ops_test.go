package ops

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"math/big"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const seeded = `apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: bluefin
controllerManager:
  extraArgs:
  - name: flex-volume-plugin-dir
    value: /var/lib/kubelet/volumeplugins
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
`

func withRoot(t *testing.T) string {
	t.Helper()
	Root = t.TempDir()
	t.Cleanup(func() { Root = "" })
	return Root
}

func TestPatchInitConfigIsIdempotent(t *testing.T) {
	root := withRoot(t)
	file := filepath.Join(root, KubeadmInitConfig)
	_ = os.MkdirAll(filepath.Dir(file), 0o755)
	_ = os.WriteFile(file, []byte(seeded), 0o644)
	changed, err := PatchInitConfig("cp1", []string{"192.0.2.10", "2001:db8::10"})
	if err != nil || !changed {
		t.Fatal(changed, err)
	}
	data, _ := os.ReadFile(file)
	s := string(data)
	for _, want := range []string{"controlPlaneEndpoint: cp1.local:6443\n", "  - cp1.local\n", "  - cp1\n", "  - \"192.0.2.10\"\n", "kind: KubeletConfiguration"} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q in\n%s", want, s)
		}
	}
	if i, j := strings.Index(s, "controlPlaneEndpoint"), strings.Index(s, "kind: KubeletConfiguration"); i > j {
		t.Fatal("endpoint not in the ClusterConfiguration")
	}
	if changed, err := PatchInitConfig("cp1", nil); changed || err != nil {
		t.Fatal("second patch must be a no-op", changed, err)
	}
}

func TestPatchInitConfigLeavesOperatorAPIServerAlone(t *testing.T) {
	root := withRoot(t)
	file := filepath.Join(root, KubeadmInitConfig)
	_ = os.MkdirAll(filepath.Dir(file), 0o755)
	_ = os.WriteFile(file, []byte(strings.Replace(seeded, "clusterName: bluefin\n", "clusterName: bluefin\napiServer:\n  certSANs: [x]\n", 1)), 0o644)
	if _, err := PatchInitConfig("cp1", nil); err == nil {
		t.Fatal("expected an error for an existing apiServer section")
	}
}

func TestCACertHashIsSPKISHA256(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "kubernetes"}, NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true}
	der, _ := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	path := filepath.Join(t.TempDir(), "ca.crt")
	_ = os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	got, err := CACertHash(path)
	cert, _ := x509.ParseCertificate(der)
	sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	if err != nil || got != hex.EncodeToString(sum[:]) {
		t.Fatal(got, err)
	}
}

func TestHostMinterKubeadm(t *testing.T) {
	root := withRoot(t)
	_ = os.MkdirAll(filepath.Join(root, "etc/kubernetes/pki"), 0o755)
	_ = os.WriteFile(filepath.Join(root, KubeadmAdminConf), []byte("clusters:\n- cluster:\n    server: https://cp1.local:6443\n"), 0o600)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour)}
	der, _ := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	_ = os.WriteFile(filepath.Join(root, KubeadmCACert), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	var args []string
	orig := Run
	t.Cleanup(func() { Run = orig })
	Run = func(_ context.Context, name string, a ...string) ([]byte, error) {
		args = append([]string{name}, a...)
		return []byte("abcdef.0123456789abcdef\n"), nil
	}
	g, err := HostMinter{}.Mint(context.Background(), "node-1")
	if err != nil {
		t.Fatal(err)
	}
	if err := g.Validate(); err != nil || g.Endpoint != "cp1.local:6443" || g.TTLSeconds != 900 {
		t.Fatalf("%+v %v", g, err)
	}
	if got := strings.Join(args, " "); !strings.Contains(got, "token create") || !strings.Contains(got, "--ttl 15m0s") {
		t.Fatalf("kubeadm args: %s", got)
	}
	cfg := JoinConfiguration(g)
	for _, want := range []string{"kind: JoinConfiguration", `apiServerEndpoint: "cp1.local:6443"`, `token: "abcdef.0123456789abcdef"`, "caCertHashes:", "criSocket: unix:///run/containerd/containerd.sock"} {
		if !strings.Contains(cfg, want) {
			t.Fatalf("missing %q:\n%s", want, cfg)
		}
	}
	if strings.Contains(cfg, "unsafeSkipCAVerification") {
		t.Fatal("unsafe skip in the join config")
	}
}

func TestGrantValidateRejectsInjection(t *testing.T) {
	g := Grant{Runtime: RuntimeKubeadm, Endpoint: "cp.local:6443", Token: "abcdef.0123456789abcdef", CACertHashes: []string{"sha256:" + strings.Repeat("a", 64)}, TTLSeconds: 900}
	if g.Validate() != nil {
		t.Fatal("valid grant rejected")
	}
	for _, mut := range []func(*Grant){
		func(g *Grant) { g.Endpoint = "cp.local:6443\nfoo: bar" },
		func(g *Grant) { g.Token = "abc" },
		func(g *Grant) { g.CACertHashes = []string{"md5:x"} },
		func(g *Grant) { g.CACertHashes = nil },
		func(g *Grant) { g.Runtime = "nomad" },
	} {
		bad := g
		mut(&bad)
		if bad.Validate() == nil {
			t.Fatalf("accepted %+v", bad)
		}
	}
}

func TestEnsureHostnameKeepsANamedHost(t *testing.T) {
	h, _ := os.Hostname()
	if strings.HasPrefix(h, "localhost") {
		t.Skip("test host is called localhost")
	}
	called := false
	Run = func(context.Context, string, ...string) ([]byte, error) { called = true; return nil, nil }
	orig := Run
	t.Cleanup(func() { Run = orig })
	if _, err := EnsureHostname(context.Background()); err != nil || called {
		t.Fatal("a named host must keep its name", err)
	}
}

func TestPinHostKeepsOneManagedLine(t *testing.T) {
	root := withRoot(t)
	file := filepath.Join(root, "etc/hosts")
	_ = os.MkdirAll(filepath.Dir(file), 0o755)
	_ = os.WriteFile(file, []byte("127.0.0.1 localhost\n"), 0o644)
	if changed, err := PinHost("cp1.local", netip.MustParseAddr("192.0.2.10")); err != nil || !changed {
		t.Fatal(changed, err)
	}
	if changed, _ := PinHost("cp1.local", netip.MustParseAddr("192.0.2.10")); changed {
		t.Fatal("unchanged address rewrote /etc/hosts")
	}
	if _, err := PinHost("cp1.local", netip.MustParseAddr("192.0.2.11")); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(file)
	want := "127.0.0.1 localhost\n" + hostsBegin + "\n192.0.2.11 cp1.local\n" + hostsEnd + "\n"
	if string(data) != want {
		t.Fatalf("got %q", data)
	}
}
