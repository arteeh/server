package conf

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseAndRemoveKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "homelab.conf")
	body := "# comment\nHOMELAB_ROLE=node\nHOMELAB_JOIN_PASSPHRASE=\"a b c d\"\n;x\nHOMELAB_METALLB_ADDRESSES=192.0.2.1-192.0.2.9\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil || c.Role() != RoleNode || c["HOMELAB_JOIN_PASSPHRASE"] != "a b c d" {
		t.Fatalf("%v %v", c, err)
	}
	if err := RemoveKey(path, "HOMELAB_JOIN_PASSPHRASE"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if want := "# comment\nHOMELAB_ROLE=node\n;x\nHOMELAB_METALLB_ADDRESSES=192.0.2.1-192.0.2.9\n"; string(data) != want {
		t.Fatalf("got %q", data)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	if err := RemoveKey(path, "HOMELAB_JOIN_PASSPHRASE"); err != nil {
		t.Fatal("second removal must be a no-op")
	}
}
