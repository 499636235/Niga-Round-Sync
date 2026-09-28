// Command wdavproxy is a logging reverse proxy in front of a real WebDAV server.
//
// It exists to answer two questions that cannot be answered from the client side alone:
//
//  1. What does a real server do with MOVE + Overwrite: F when the target already exists?
//     rclone 1.71.0 always sends Overwrite: T and pre-deletes the target, so the only way to
//     probe the server's own conflict behaviour is to rewrite the header in flight.
//  2. Which verbs does a given client sequence actually produce, and can a response be lost?
//
// Credentials are never handled here: the Authorization header is forwarded untouched, so the
// password stays inside the client that already has it.
//
//	go run ./tools/wdavproxy -listen 127.0.0.1:30090 -upstream http://192.168.1.101:5005 \
//	    -rewrite-overwrite F -log move-f.jsonl
//
// Then point the WebDAV client at http://127.0.0.1:30090/ (keep the same path prefix).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type record struct {
	Time        string `json:"time"`
	Method      string `json:"method"`
	Path        string `json:"path"`
	Destination string `json:"destination,omitempty"`
	Overwrite   string `json:"overwrite,omitempty"`
	SentOverw   string `json:"overwriteSentUpstream,omitempty"`
	Depth       string `json:"depth,omitempty"`
	If          string `json:"if,omitempty"`
	Status      int    `json:"status"`
	Bytes       int64  `json:"bytes"`
	ElapsedMS   int64  `json:"elapsedMs"`
	Error       string `json:"error,omitempty"`
}

type counter struct {
	mu     sync.Mutex
	counts map[string]int
}

func (c *counter) add(k string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counts[k]++
}

func (c *counter) snapshot() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]int, len(c.counts))
	for k, v := range c.counts {
		out[k] = v
	}
	return out
}

// statusRecorder also lets us answer requests locally without touching the upstream.
type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (w *statusRecorder) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusRecorder) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(p)
	w.bytes += int64(n)
	return n, err
}

func main() {
	var (
		listen       = flag.String("listen", "127.0.0.1:30090", "address to bind")
		upstream     = flag.String("upstream", "", "real WebDAV base URL, e.g. http://192.168.1.101:5005 (required)")
		logPath      = flag.String("log", "", "JSONL request/response log")
		rewriteOverw = flag.String("rewrite-overwrite", "", "force this value into the Overwrite header of every write request (T|F|keep)")
		failStatus   = flag.Int("fail", 0, "answer this status to every write verb without contacting upstream")
		delay        = flag.Duration("delay", 0, "delay before forwarding write verbs")
		dropResponse = flag.Bool("drop-response", false, "forward the write but destroy the response (lost-reply injection)")
	)
	flag.Parse()

	if *upstream == "" {
		fmt.Fprintln(os.Stderr, "-upstream is required")
		os.Exit(2)
	}
	target, err := url.Parse(*upstream)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	var logOut io.Writer = io.Discard
	if *logPath != "" {
		f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer f.Close()
		logOut = f
	}

	counts := &counter{counts: map[string]int{}}
	enc := json.NewEncoder(logOut)
	var encMu sync.Mutex

	// The client already holds the credentials. Keep a copy of the Authorization header in
	// memory so the probe endpoint below can issue raw verbs the client itself never sends.
	// It is never written to the log or to disk.
	var authMu sync.Mutex
	var lastAuth string
	rememberAuth := func(h string) {
		if h == "" {
			return
		}
		authMu.Lock()
		defer authMu.Unlock()
		lastAuth = h
	}
	takeAuth := func() string {
		authMu.Lock()
		defer authMu.Unlock()
		return lastAuth
	}

	proxy := &httputil.ReverseProxy{
		Director: func(r *http.Request) {
			r.URL.Scheme = target.Scheme
			r.URL.Host = target.Host
			// Destination is absolute in WebDAV; rewrite it too so the server accepts it.
			if d := r.Header.Get("Destination"); d != "" {
				if du, err := url.Parse(d); err == nil {
					du.Scheme = target.Scheme
					du.Host = target.Host
					r.Header.Set("Destination", du.String())
				}
			}
			if *rewriteOverw != "" && *rewriteOverw != "keep" && isWrite(r.Method) {
				r.Header.Set("Overwrite", *rewriteOverw)
			}
			r.Host = target.Host
		},
		ModifyResponse: func(resp *http.Response) error {
			if *dropResponse && isWrite(resp.Request.Method) {
				counts.add("RESPONSE_DROPPED")
				// Close without delivering: the client sees a broken connection.
				return fmt.Errorf("dropped response on purpose")
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			encMu.Lock()
			_ = enc.Encode(record{Time: time.Now().UTC().Format(time.RFC3339Nano), Method: r.Method,
				Path: r.URL.Path, Error: err.Error()})
			encMu.Unlock()
		},
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		if r.URL.Path == "/__counts" {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(counts.snapshot())
			return
		}
		if r.URL.Path == "/__probe/move" {
			probeMove(w, r, target, takeAuth())
			return
		}
		rememberAuth(r.Header.Get("Authorization"))
		counts.add(r.Method)
		rec := &statusRecorder{ResponseWriter: w}
		overwriteSeen := r.Header.Get("Overwrite")
		sentOverwrite := overwriteSeen
		if *rewriteOverw != "" && *rewriteOverw != "keep" && isWrite(r.Method) {
			sentOverwrite = *rewriteOverw
		}
		defer func() {
			encMu.Lock()
			_ = enc.Encode(record{
				Time: start.UTC().Format(time.RFC3339Nano), Method: r.Method, Path: r.URL.Path,
				Destination: r.Header.Get("Destination"), Overwrite: overwriteSeen,
				SentOverw: sentOverwrite, Depth: r.Header.Get("Depth"), If: r.Header.Get("If"),
				Status: rec.status, Bytes: rec.bytes, ElapsedMS: time.Since(start).Milliseconds(),
			})
			encMu.Unlock()
		}()

		if *failStatus != 0 && isWrite(r.Method) {
			time.Sleep(*delay)
			rec.WriteHeader(*failStatus)
			fmt.Fprintf(rec, "wdavproxy injected %d for %s\n", *failStatus, r.Method)
			return
		}
		if *delay != 0 && isWrite(r.Method) {
			time.Sleep(*delay)
		}
		proxy.ServeHTTP(rec, r)
	})

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("wdavproxy http://%s -> %s (log=%s rewriteOverwrite=%q fail=%d drop=%v)\n",
		*listen, *upstream, *logPath, *rewriteOverw, *failStatus, *dropResponse)
	if err := http.Serve(ln, handler); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func isWrite(method string) bool {
	switch strings.ToUpper(method) {
	case "PUT", "POST", "DELETE", "MOVE", "COPY", "MKCOL", "PROPPATCH", "LOCK", "UNLOCK":
		return true
	}
	return false
}

// probeMove issues one raw MOVE against the upstream with an explicit Overwrite value, so a
// test can ask "does this server honour Overwrite: F with 412?" independently of what rclone
// sends. Usage: POST /__probe/move?src=/path/a&dst=/path/b&overwrite=F
func probeMove(w http.ResponseWriter, r *http.Request, target *url.URL, auth string) {
	q := r.URL.Query()
	src, dst, overw := q.Get("src"), q.Get("dst"), strings.ToUpper(q.Get("overwrite"))
	if src == "" || dst == "" {
		http.Error(w, "src and dst are required", http.StatusBadRequest)
		return
	}
	if overw != "F" && overw != "T" {
		overw = "T"
	}
	if auth == "" {
		http.Error(w, "no Authorization header captured yet; run one normal request through the proxy first", http.StatusPreconditionFailed)
		return
	}
	req, err := http.NewRequest("MOVE", target.Scheme+"://"+target.Host+src, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	req.Header.Set("Authorization", auth)
	req.Header.Set("Overwrite", overw)
	du, err := url.Parse(target.Scheme + "://" + target.Host + dst)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	req.Header.Set("Destination", du.String())

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "upstream request failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"request":      map[string]string{"method": "MOVE", "src": src, "dst": dst, "overwrite": overw},
		"status":       resp.StatusCode,
		"statusText":   resp.Status,
		"body":         strings.TrimSpace(string(body)),
		"destination":  du.String(),
		"responseHead": firstLines(resp),
	})
}

func firstLines(resp *http.Response) string {
	var b strings.Builder
	for _, k := range []string{"Content-Length", "Location", "ETag", "DST-Of", "MS-Version", "Server"} {
		if v := resp.Header.Get(k); v != "" {
			fmt.Fprintf(&b, "%s: %s; ", k, v)
		}
	}
	return b.String()
}
