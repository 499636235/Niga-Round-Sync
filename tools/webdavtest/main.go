// Command webdavtest is the acceptance harness for the Round Sync move work: an independent
// RFC 4918 WebDAV server (golang.org/x/net/webdav) that logs every request and can inject the
// failures the plan requires (405/501 for MOVE, forced 412, lost response, read-only prefix).
//
//	go run ./tools/webdavtest -root D:/Development/RoundSyncTestAssets/rs-test \
//	    -listen 127.0.0.1:30080 -log requests.jsonl
//
// The log is JSONL: one record per request, carrying the headers that decide move safety
// (Destination, Overwrite, If, Depth). GET /__counts returns per-method totals, which is how
// the "no client-side DELETE/PUT/COPY fallback" assertions (D05, D06, D11) are made instead of
// only checking the final file listing.
//
// The corpus is served from memory, so a run cannot damage the files on disk.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/webdav"
)

type config struct {
	root           string
	listen         string
	logPath        string
	prefixReadOnly string
	moveStatus     int
	moveDelay      time.Duration
	forceConflict  bool
	dropAfterMove  bool
}

type record struct {
	Time          string `json:"time"`
	Method        string `json:"method"`
	Path          string `json:"path"`
	Destination   string `json:"destination,omitempty"`
	Overwrite     string `json:"overwrite,omitempty"`
	Depth         string `json:"depth,omitempty"`
	If            string `json:"if,omitempty"`
	ContentLength int64  `json:"contentLength"`
	Status        int    `json:"status"`
	Bytes         int64  `json:"bytes"`
	ElapsedMS     int64  `json:"elapsedMs"`
}

type summary struct {
	mu     sync.Mutex
	counts map[string]int
}

func (s *summary) add(method string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.counts[method]++
}

func (s *summary) snapshot() map[string]int {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]int, len(s.counts))
	for k, v := range s.counts {
		out[k] = v
	}
	return out
}

func (s *summary) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.counts = map[string]int{}
}

// statusWriter records the status and byte count of a response. When swallow is set the
// response body and headers are discarded, which is what the lost-response injection needs.
type statusWriter struct {
	http.ResponseWriter
	status  int
	bytes   int64
	swallow bool
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	if !w.swallow {
		w.ResponseWriter.WriteHeader(code)
	}
}

func (w *statusWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if w.swallow {
		return len(p), nil
	}
	n, err := w.ResponseWriter.Write(p)
	w.bytes += int64(n)
	return n, err
}

func main() {
	cfg := &config{}
	flag.StringVar(&cfg.root, "root", "", "directory exposed as the WebDAV root (required)")
	flag.StringVar(&cfg.listen, "listen", "127.0.0.1:30080", "host:port; 0.0.0.0 lets an emulator or phone connect")
	flag.StringVar(&cfg.logPath, "log", "", "JSONL request log")
	flag.StringVar(&cfg.prefixReadOnly, "prefix-readonly", "", "answer 403 for writes under this URL path prefix")
	flag.IntVar(&cfg.moveStatus, "move-status", 0, "answer every MOVE with this status (405, 501, ...)")
	flag.DurationVar(&cfg.moveDelay, "move-delay", 0, "delay before handling MOVE")
	flag.BoolVar(&cfg.forceConflict, "force-conflict", false, "answer 412 for every MOVE regardless of Overwrite")
	flag.BoolVar(&cfg.dropAfterMove, "drop-after-move", false, "perform the MOVE but destroy the response so the client cannot learn the outcome")
	flag.Parse()

	if cfg.root == "" {
		fmt.Fprintln(os.Stderr, "-root is required")
		os.Exit(2)
	}
	abs, err := filepath.Abs(cfg.root)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	var logOut io.Writer = io.Discard
	if cfg.logPath != "" {
		f, err := os.OpenFile(cfg.logPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer f.Close()
		logOut = f
	}

	h := &handler{cfg: cfg, counts: &summary{counts: map[string]int{}}, encoder: json.NewEncoder(logOut)}
	h.dav = &webdav.Handler{
		Prefix:     "/",
		FileSystem: webdav.NewMemFS(),
		LockSystem: webdav.NewMemLS(),
	}
	if err := h.seedFromDisk(abs); err != nil {
		fmt.Fprintf(os.Stderr, "seed: %v\n", err)
		os.Exit(1)
	}

	ln, err := net.Listen("tcp", cfg.listen)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("webdavtest listening on http://%s serving %s (log=%s)\n", cfg.listen, abs, cfg.logPath)
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 30 * time.Second}
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type handler struct {
	cfg     *config
	counts  *summary
	mu      sync.Mutex
	encoder *json.Encoder
	dav     http.Handler
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	if strings.HasPrefix(r.URL.Path, "/__counts") {
		if r.Method == "POST" {
			h.counts.reset()
			fmt.Fprintln(w, "reset")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(h.counts.snapshot())
		return
	}

	h.counts.add(r.Method)
	sw := &statusWriter{ResponseWriter: w}
	defer func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		_ = h.encoder.Encode(record{
			Time:          start.UTC().Format(time.RFC3339Nano),
			Method:        r.Method,
			Path:          r.URL.Path,
			Destination:   r.Header.Get("Destination"),
			Overwrite:     r.Header.Get("Overwrite"),
			Depth:         r.Header.Get("Depth"),
			If:            r.Header.Get("If"),
			ContentLength: r.ContentLength,
			Status:        sw.status,
			Bytes:         sw.bytes,
			ElapsedMS:     time.Since(start).Milliseconds(),
		})
	}()

	if h.cfg.prefixReadOnly != "" && isWrite(r.Method) &&
		strings.HasPrefix(r.URL.Path, h.cfg.prefixReadOnly) {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprint(w, "403 forbidden by webdavtest\n")
		return
	}

	switch {
	case r.Method == "MOVE" && h.cfg.moveStatus != 0:
		time.Sleep(h.cfg.moveDelay)
		w.WriteHeader(h.cfg.moveStatus)
		fmt.Fprintf(w, "webdavtest injected %d for MOVE\n", h.cfg.moveStatus)

	case r.Method == "MOVE" && h.cfg.forceConflict:
		time.Sleep(h.cfg.moveDelay)
		w.WriteHeader(http.StatusPreconditionFailed)
		fmt.Fprint(w, "webdavtest injected 412 for MOVE\n")

	case r.Method == "MOVE" && h.cfg.dropAfterMove:
		// The rename happens server side, then the response is destroyed: the client
		// must classify this as unknown, never as failure-to-retry-or-rollback.
		time.Sleep(h.cfg.moveDelay)
		h.counts.add("RESPONSE_DROPPED")
		captured := &statusWriter{ResponseWriter: w, swallow: true}
		h.dav.ServeHTTP(captured, r)
		conn, _, err := http.NewResponseController(w).Hijack()
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintf(w, "could not drop connection: %v\n", err)
			return
		}
		_ = conn.Close() // client sees a reset connection, not an answer

	default:
		if r.Method == "MOVE" {
			time.Sleep(h.cfg.moveDelay)
		}
		h.dav.ServeHTTP(sw, r)
	}
}

func isWrite(method string) bool {
	switch method {
	case "PUT", "POST", "DELETE", "MOVE", "COPY", "MKCOL", "PROPPATCH":
		return true
	}
	return false
}

// seedFromDisk loads the corpus into the in-memory WebDAV filesystem. filepath.Walk visits
// parents before children, so Mkdir is enough to recreate the tree.
func (h *handler) seedFromDisk(root string) error {
	fs := h.dav.(*webdav.Handler).FileSystem
	return filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, p)
		if err != nil || rel == "." {
			return err
		}
		davPath := "/" + filepath.ToSlash(rel)
		ctx := context.Background()
		if info.IsDir() {
			return fs.Mkdir(ctx, davPath, 0o755)
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		f, err := fs.OpenFile(ctx, davPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			return err
		}
		if _, err := f.Write(data); err != nil {
			_ = f.Close()
			return err
		}
		return f.Close()
	})
}
