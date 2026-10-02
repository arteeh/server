package join

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/netip"
	"sync"
	"time"

	"filippo.io/cpace"

	"github.com/projectbluefin/server/files/homelab/cluster/internal/ops"
)

// Payload is the sealed message a node receives.
type Payload struct {
	Cluster string    `json:"cluster"`
	Grant   ops.Grant `json:"grant"`
}

type Server struct {
	Passphrase  string // normalised
	Cluster     string
	Cert        tls.Certificate
	Runtime     func() string
	Minter      ops.Minter
	Limiter     *Limiter
	Mints       *MintLimiter
	Log         *slog.Logger
	HelloWait   time.Duration
	ConnTimeout time.Duration
	MaxConns    int
}

func (s *Server) defaults() {
	if s.Log == nil {
		s.Log = slog.Default()
	}
	if s.HelloWait == 0 {
		s.HelloWait = 10 * time.Second
	}
	if s.ConnTimeout == 0 {
		s.ConnTimeout = 30 * time.Second
	}
	if s.MaxConns == 0 {
		s.MaxConns = 4
	}
	if s.Mints == nil {
		s.Mints = NewMintLimiter(10, time.Hour, nil)
	}
}

// Serve accepts connections until ctx ends.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	s.defaults()
	tl := tls.NewListener(ln, &tls.Config{
		Certificates:           []tls.Certificate{s.Cert},
		MinVersion:             tls.VersionTLS13,
		SessionTicketsDisabled: true,
	})
	stop := context.AfterFunc(ctx, func() { tl.Close() })
	defer stop()
	slots := make(chan struct{}, s.MaxConns)
	var wg sync.WaitGroup
	defer wg.Wait()
	for {
		c, err := tl.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		select {
		case slots <- struct{}{}:
		default:
			c.Close()
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-slots }()
			defer c.Close()
			defer func() {
				if r := recover(); r != nil {
					s.Log.Error("join connection panicked", "panic", r)
				}
			}()
			s.handle(ctx, c.(*tls.Conn))
		}()
	}
}

func remoteAddr(c net.Conn) netip.Addr {
	ap, err := netip.ParseAddrPort(c.RemoteAddr().String())
	if err != nil {
		return netip.Addr{}
	}
	return ap.Addr()
}

func (s *Server) refuse(c net.Conn, code string, retry time.Duration) {
	_ = writeFrame(c, serverReply{Error: code, RetryAfter: int((retry + time.Second - 1) / time.Second)})
}

func (s *Server) handle(ctx context.Context, c *tls.Conn) {
	defer context.AfterFunc(ctx, func() { c.Close() })()
	start := time.Now()
	_ = c.SetDeadline(start.Add(s.HelloWait))
	hctx, cancel := context.WithTimeout(ctx, s.HelloWait)
	err := c.HandshakeContext(hctx)
	cancel()
	if err != nil {
		return
	}
	src := remoteAddr(c)
	log := s.Log.With("peer", src.String())

	var h hello
	if err := readFrame(c, &h); err != nil {
		return
	}
	if h.V != Version || !ops.ValidHostname(h.Node) || len(h.PAKE) != msgALen {
		s.refuse(c, ErrCodeBadRequest, 0)
		return
	}
	runtime := s.Runtime()
	if runtime == "" {
		s.refuse(c, ErrCodeUnavailable, 30*time.Second)
		return
	}
	if h.Runtime != runtime {
		s.refuse(c, ErrCodeRuntime, 0)
		return
	}
	_ = c.SetDeadline(start.Add(s.ConnTimeout))

	attempt, retry, busy, ok := s.Limiter.Begin(SourceKey(src))
	if !ok {
		if busy {
			s.refuse(c, ErrCodeBusy, retry)
		} else {
			log.Warn("join attempt rate-limited", "retryAfter", retry.Round(time.Second))
			s.refuse(c, ErrCodeRateLimited, retry)
		}
		return
	}
	defer s.Limiter.Done(attempt)

	b, err := bindingOf(c.ConnectionState(), s.Cert.Certificate[0])
	if err != nil {
		return
	}
	msgB, isk, err := cpace.Exchange(s.Passphrase, b.contextInfo(), h.PAKE)
	if err != nil {
		log.Warn("join attempt failed: invalid PAKE message", "node", h.Node)
		return
	}
	k, err := schedule(isk, b, h, msgB)
	if err != nil {
		return
	}
	if err := writeFrame(c, serverReply{PAKE: msgB, Confirm: tag(k.server, k.th)}); err != nil {
		return
	}
	var cc clientConfirm
	if err := readFrame(c, &cc); err != nil || len(cc.Confirm) != tagLen ||
		subtle.ConstantTimeCompare(cc.Confirm, tag(k.client, k.th)) != 1 {
		log.Warn("join attempt failed: node did not prove the passphrase", "node", h.Node)
		s.refuse(c, ErrCodeDenied, 0)
		return
	}
	s.Limiter.Succeed(attempt)

	if !s.Mints.Allow() {
		log.Warn("join token mint limit reached", "node", h.Node)
		s.refuse(c, ErrCodeBusy, time.Minute)
		return
	}
	g, err := s.Minter.Mint(ctx, h.Node)
	if err != nil {
		log.Error("minting a join token failed", "node", h.Node, "error", err)
		s.refuse(c, ErrCodeUnavailable, 30*time.Second)
		return
	}
	plain, err := json.Marshal(Payload{Cluster: s.Cluster, Grant: g})
	if err != nil {
		return
	}
	sealed, err := seal(k, plain)
	if err != nil {
		return
	}
	if err := writeFrame(c, serverReply{Sealed: sealed}); err != nil {
		return
	}
	log.Info("issued a join token", "node", h.Node, "runtime", g.Runtime, "ttl", g.TTLSeconds)
}
