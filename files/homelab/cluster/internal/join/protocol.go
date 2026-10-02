// Package join is the bluefin-cluster join protocol: a node that knows the
// cluster's join passphrase gets a fresh, short-lived join token from the
// control plane, and both sides prove knowledge of the passphrase without
// sending it. See README.md next to go.mod for the specification and the
// threat model.
package join

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"filippo.io/cpace"
)

const (
	Version  = 1
	protocol = "bluefin-cluster/v1"
	// RFC 9266 tls-exporter channel binding.
	exporterLabel = "EXPORTER-Channel-Binding"
	maxFrame      = 64 << 10
	msgALen       = 16 + 32
	msgBLen       = 32
	tagLen        = sha256.Size
	nodeIdentity  = "bluefin-cluster node"
	cpIdentity    = "bluefin-cluster control-plane"
)

// Server error codes; never more specific than this, so a refusal tells a
// client nothing about the passphrase.
const (
	ErrCodeRateLimited = "rate-limited"
	ErrCodeBusy        = "busy"
	ErrCodeDenied      = "denied"
	ErrCodeBadRequest  = "bad-request"
	ErrCodeRuntime     = "runtime-mismatch"
	ErrCodeUnavailable = "unavailable"
)

type hello struct {
	V       int    `json:"v"`
	Node    string `json:"node"`
	Runtime string `json:"runtime"`
	PAKE    []byte `json:"pake"`
}

type serverReply struct {
	PAKE       []byte `json:"pake,omitempty"`
	Confirm    []byte `json:"confirm,omitempty"`
	Sealed     []byte `json:"sealed,omitempty"`
	Error      string `json:"error,omitempty"`
	RetryAfter int    `json:"retryAfter,omitempty"`
}

type clientConfirm struct {
	Confirm []byte `json:"confirm"`
}

func writeFrame(w io.Writer, v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(body) > maxFrame {
		return errors.New("frame too large")
	}
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(body)))
	_, err = w.Write(append(hdr[:], body...))
	return err
}

// readFrame decodes exactly one JSON object with no unknown fields.
func readFrame(r io.Reader, v any) error {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n == 0 || n > maxFrame {
		return errors.New("bad frame length")
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if dec.More() {
		return errors.New("trailing data in frame")
	}
	return nil
}

// binding ties the PAKE to one TLS connection: the RFC 9266 exporter
// (unique per TLS 1.3 connection) and the server's certificate.
type binding struct {
	exporter []byte
	certHash [32]byte
}

func bindingOf(cs tls.ConnectionState, leafDER []byte) (binding, error) {
	if cs.Version != tls.VersionTLS13 || !cs.HandshakeComplete {
		return binding{}, errors.New("TLS 1.3 handshake required")
	}
	ekm, err := cs.ExportKeyingMaterial(exporterLabel, nil, 32)
	if err != nil {
		return binding{}, err
	}
	return binding{exporter: ekm, certHash: sha256.Sum256(leafDER)}, nil
}

func lp(b *bytes.Buffer, parts ...[]byte) {
	for _, p := range parts {
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], uint32(len(p)))
		b.Write(n[:])
		b.Write(p)
	}
}

func (b binding) contextInfo() *cpace.ContextInfo {
	var ad bytes.Buffer
	lp(&ad, []byte(protocol), b.exporter, b.certHash[:])
	return cpace.NewContextInfo(nodeIdentity, cpIdentity, ad.Bytes())
}

type keys struct {
	th                   []byte
	server, client, aead []byte
}

// schedule: th = SHA-256 of the length-prefixed transcript; three 32-byte
// keys from HKDF-SHA256(ISK) with distinct labels, each bound to th.
func schedule(isk []byte, b binding, h hello, msgB []byte) (keys, error) {
	var t bytes.Buffer
	lp(&t, []byte(protocol), b.exporter, b.certHash[:], h.PAKE, msgB, []byte(h.Node), []byte(h.Runtime))
	sum := sha256.Sum256(t.Bytes())
	k := keys{th: sum[:]}
	prk, err := hkdf.Extract(sha256.New, isk, nil)
	if err != nil {
		return keys{}, err
	}
	for _, out := range []struct {
		dst   *[]byte
		label string
	}{{&k.server, "server confirm"}, {&k.client, "client confirm"}, {&k.aead, "payload"}} {
		*out.dst, err = hkdf.Expand(sha256.New, prk, protocol+" "+out.label+" "+string(k.th), 32)
		if err != nil {
			return keys{}, err
		}
	}
	return k, nil
}

func tag(key, th []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(th)
	return m.Sum(nil)
}

func seal(k keys, plaintext []byte) ([]byte, error) {
	gcm, err := newGCM(k.aead)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, plaintext, k.th), nil
}

func open(k keys, sealed []byte) ([]byte, error) {
	gcm, err := newGCM(k.aead)
	if err != nil {
		return nil, err
	}
	if len(sealed) < gcm.NonceSize()+gcm.Overhead() {
		return nil, errors.New("sealed payload too short")
	}
	return gcm.Open(nil, sealed[:gcm.NonceSize()], sealed[gcm.NonceSize():], k.th)
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// ServerError is a refusal the control plane sent.
type ServerError struct {
	Code       string
	RetryAfter int
}

func (e *ServerError) Error() string {
	if e.RetryAfter > 0 {
		return fmt.Sprintf("control plane refused: %s (retry after %ds)", e.Code, e.RetryAfter)
	}
	return "control plane refused: " + e.Code
}
