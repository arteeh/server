package join

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"time"

	"filippo.io/cpace"
)

// ErrNotProven means the peer could not prove the passphrase: either the
// node's passphrase is wrong or the peer is not the control plane.
var ErrNotProven = errors.New("the control plane could not prove the passphrase (wrong passphrase, or an impostor)")

// ErrBudget means the node used up its guess budget; wait RetryAfter.
type ErrBudget struct{ RetryAfter time.Duration }

func (e *ErrBudget) Error() string {
	return fmt.Sprintf("join attempt budget exhausted; retry in %s", e.RetryAfter.Round(time.Second))
}

type Client struct {
	Passphrase string // normalised
	Node       string
	Runtime    string
	Budget     *ClientBudget
	Timeout    time.Duration
	// Dial is replaced by tests (relay); nil dials TCP.
	Dial func(ctx context.Context, addr string) (net.Conn, error)
}

// Join runs the exchange against one address and returns the validated
// payload.
func (cl *Client) Join(ctx context.Context, addr netip.AddrPort) (Payload, error) {
	timeout := cl.Timeout
	if timeout == 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	dial := cl.Dial
	if dial == nil {
		dial = func(ctx context.Context, a string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "tcp", a)
		}
	}
	raw, err := dial(ctx, addr.String())
	if err != nil {
		return Payload{}, err
	}
	defer raw.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = raw.SetDeadline(dl)
	}
	// The certificate is not verified against a CA: the PAKE, bound to
	// this connection's exporter and certificate, authenticates the peer.
	c := tls.Client(raw, &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true,
		ServerName:         "bluefin-cluster",
	})
	if err := c.HandshakeContext(ctx); err != nil {
		return Payload{}, err
	}
	cs := c.ConnectionState()
	if len(cs.PeerCertificates) == 0 {
		return Payload{}, errors.New("control plane sent no certificate")
	}
	b, err := bindingOf(cs, cs.PeerCertificates[0].Raw)
	if err != nil {
		return Payload{}, err
	}

	if wait, ok := cl.Budget.Take(); !ok {
		return Payload{}, &ErrBudget{RetryAfter: wait}
	}
	msgA, state, err := cpace.Start(cl.Passphrase, b.contextInfo())
	if err != nil {
		cl.Budget.Refund()
		return Payload{}, err
	}
	h := hello{V: Version, Node: cl.Node, Runtime: cl.Runtime, PAKE: msgA}
	var r serverReply
	if err := writeFrame(c, h); err != nil {
		cl.Budget.Refund()
		return Payload{}, err
	}
	if err := readFrame(c, &r); err != nil {
		// msgA alone lets a peer test no guess: only an answered PAKE
		// (msgB) counts against the budget.
		cl.Budget.Refund()
		return Payload{}, err
	}
	if r.Error != "" {
		cl.Budget.Refund()
		return Payload{}, &ServerError{Code: r.Error, RetryAfter: r.RetryAfter}
	}
	if len(r.PAKE) != msgBLen || len(r.Confirm) != tagLen {
		return Payload{}, ErrNotProven
	}
	isk, err := state.Finish(r.PAKE)
	if err != nil {
		return Payload{}, ErrNotProven
	}
	k, err := schedule(isk, b, h, r.PAKE)
	if err != nil {
		return Payload{}, err
	}
	if subtle.ConstantTimeCompare(r.Confirm, tag(k.server, k.th)) != 1 {
		return Payload{}, ErrNotProven
	}
	cl.Budget.Refund()

	if err := writeFrame(c, clientConfirm{Confirm: tag(k.client, k.th)}); err != nil {
		return Payload{}, err
	}
	var sealed serverReply
	if err := readFrame(c, &sealed); err != nil {
		return Payload{}, err
	}
	if sealed.Error != "" {
		return Payload{}, &ServerError{Code: sealed.Error, RetryAfter: sealed.RetryAfter}
	}
	plain, err := open(k, sealed.Sealed)
	if err != nil {
		return Payload{}, errors.New("sealed payload failed authentication")
	}
	var p Payload
	if err := json.Unmarshal(plain, &p); err != nil {
		return Payload{}, err
	}
	if p.Grant.Runtime != cl.Runtime {
		return Payload{}, fmt.Errorf("control plane granted a %q join, this node runs %q", p.Grant.Runtime, cl.Runtime)
	}
	if err := p.Grant.Validate(); err != nil {
		return Payload{}, err
	}
	return p, nil
}
