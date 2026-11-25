package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	nd "github.com/wgx0307/netdisk"
)

const maxBody = 16 << 10

var idPattern = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)

type share struct {
	ShareURL string `json:"shareURL"`
	Code     string `json:"code"`
	Title    string `json:"title"`
}

type transferInput struct {
	ID   string `json:"id"`
	URL  string `json:"url"`
	Code string `json:"code"`
}

type failure struct {
	Error     string `json:"error"`
	Uncertain bool   `json:"uncertain"`
}

type record struct {
	ShareURL string `json:"shareURL"`
	Code     string `json:"code"`
	Title    string `json:"title"`
}

type ledger struct {
	mu      sync.Mutex
	file    string
	results map[string]record
}

func loadLedger(file string) (*ledger, error) {
	l := &ledger{file: file, results: make(map[string]record)}
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return l, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &l.results); err != nil {
		return nil, fmt.Errorf("invalid transfer ledger: %w", err)
	}
	return l, nil
}

func (l *ledger) get(id string) (record, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	r, ok := l.results[id]
	return r, ok
}

func (l *ledger) put(id string, r record) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.results[id] = r
	b, err := json.MarshalIndent(l.results, "", "  ")
	if err != nil {
		delete(l.results, id)
		return err
	}
	if err := os.MkdirAll(filepath.Dir(l.file), 0700); err != nil {
		delete(l.results, id)
		return err
	}
	tmp := l.file + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		delete(l.results, id)
		return err
	}
	if err := os.Rename(tmp, l.file); err != nil {
		_ = os.Remove(tmp)
		delete(l.results, id)
		return err
	}
	return nil
}

func main() {
	apiKey := os.Getenv("CLOUDFLOW_API_KEY")
	if len(apiKey) < 32 || strings.ContainsAny(apiKey, "\r\n") {
		log.Fatal("CLOUDFLOW_API_KEY must contain at least 32 characters")
	}
	nd.InitFromEnv()
	if !anyProvider() {
		log.Fatal("configure at least one provider credential and save directory in environment")
	}
	ledgerFile := os.Getenv("CLOUDFLOW_LEDGER")
	if ledgerFile == "" {
		ledgerFile = "./data/transfers.json"
	}
	store, err := loadLedger(ledgerFile)
	if err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/status", func(w http.ResponseWriter, r *http.Request) {
		if !authorized(w, r, apiKey) {
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"providers": map[string]bool{
			"quark": nd.IsConfigured(nd.PanQuark), "xunlei": nd.IsConfigured(nd.PanXunlei), "baidu": nd.IsConfigured(nd.PanBaidu),
		}})
	})
	mux.HandleFunc("POST /api/v1/transfers", func(w http.ResponseWriter, r *http.Request) {
		if !authorized(w, r, apiKey) {
			return
		}
		var in transferInput
		if err := decodeBody(w, r, &in); err != nil {
			writeError(w, http.StatusBadRequest, err.Error(), false)
			return
		}
		if !idPattern.MatchString(in.ID) || len(in.Code) > 32 || !validShare(in.URL) {
			writeError(w, http.StatusBadRequest, "invalid transfer input", false)
			return
		}
		// The upstream SDK stores the extraction code in a package-global variable.
		// Serialize transfers so two links cannot consume each other's code.
		result, err := runTransfer(store, in)
		if err != nil {
			writeError(w, http.StatusBadGateway, err.Error(), true)
			return
		}
		writeJSON(w, http.StatusOK, result)
	})
	mux.HandleFunc("GET /api/v1/transfers/{id}", func(w http.ResponseWriter, r *http.Request) {
		if !authorized(w, r, apiKey) {
			return
		}
		id := r.PathValue("id")
		if !idPattern.MatchString(id) {
			writeError(w, http.StatusBadRequest, "invalid transfer id", false)
			return
		}
		if result, ok := store.get(id); ok {
			writeJSON(w, http.StatusOK, result)
			return
		}
		writeError(w, http.StatusNotFound, "result not in ledger; provider state may need manual inspection", true)
	})

	addr := os.Getenv("CLOUDFLOW_LISTEN")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	if host, _, err := net.SplitHostPort(addr); err != nil || (host != "127.0.0.1" && host != "localhost" && host != "[::1]") {
		log.Fatal("server must bind loopback; terminate HTTPS at a reverse proxy")
	}
	server := &http.Server{Addr: addr, Handler: securityHeaders(mux), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 10 * time.Second, WriteTimeout: 160 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
	log.Printf("CloudFlow service listening on %s; place an HTTPS reverse proxy in front for phone access", addr)
	log.Fatal(server.ListenAndServe())
}

func runTransfer(store *ledger, in transferInput) (share, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if saved, ok := store.results[in.ID]; ok {
		return share{ShareURL: saved.ShareURL, Code: saved.Code, Title: saved.Title}, nil
	}
	// Check the ledger under the same lock as the SDK's global extraction-code slot.
	result, err := nd.Transfer(in.URL, in.Code, 1, "")
	if err != nil {
		return share{}, err
	}
	if result == nil || result.ShareURL == "" {
		return share{}, errors.New("provider returned no share URL")
	}
	entry := record{ShareURL: result.ShareURL, Code: result.Code, Title: result.Title}
	if err := store.persistLocked(in.ID, entry); err != nil {
		return share{}, fmt.Errorf("transfer may have completed but ledger write failed: %w", err)
	}
	return share{ShareURL: entry.ShareURL, Code: entry.Code, Title: entry.Title}, nil
}

func (l *ledger) persistLocked(id string, result record) error {
	l.results[id] = result
	b, err := json.MarshalIndent(l.results, "", "  ")
	if err != nil {
		delete(l.results, id)
		return err
	}
	if err := os.MkdirAll(filepath.Dir(l.file), 0700); err != nil {
		delete(l.results, id)
		return err
	}
	tmp := l.file + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		delete(l.results, id)
		return err
	}
	if err := os.Rename(tmp, l.file); err != nil {
		_ = os.Remove(tmp)
		delete(l.results, id)
		return err
	}
	return nil
}

func anyProvider() bool {
	return nd.IsConfigured(nd.PanQuark) || nd.IsConfigured(nd.PanXunlei) || nd.IsConfigured(nd.PanBaidu)
}

func authorized(w http.ResponseWriter, r *http.Request, expected string) bool {
	a := strings.TrimSpace(r.Header.Get("Authorization"))
	if !strings.HasPrefix(a, "Bearer ") {
		writeError(w, http.StatusUnauthorized, "missing bearer token", false)
		return false
	}
	got := strings.TrimPrefix(a, "Bearer ")
	if subtle.ConstantTimeCompare([]byte(got), []byte(expected)) != 1 {
		writeError(w, http.StatusUnauthorized, "invalid bearer token", false)
		return false
	}
	return true
}

func decodeBody(w http.ResponseWriter, r *http.Request, dest any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dest); err != nil {
		return fmt.Errorf("invalid JSON body")
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return errors.New("request must contain one JSON object")
	}
	return nil
}

func validShare(raw string) bool {
	// Validate the parsed authority before passing the URL to the SDK's substring router.
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" || u.RawQuery != "" && len(u.RawQuery) > 2048 {
		return false
	}
	allowed := map[string]bool{"pan.quark.cn": true, "pan.xunlei.com": true, "pan.baidu.com": true}
	if !allowed[strings.ToLower(u.Hostname())] || strings.HasSuffix(u.Hostname(), ".") || u.Fragment != "" {
		return false
	}
	segments := strings.Split(strings.TrimPrefix(u.EscapedPath(), "/"), "/")
	return len(segments) == 2 && segments[0] == "s" && segments[1] != "" && regexp.MustCompile(`^[A-Za-z0-9_-]+$`).MatchString(segments[1])
}

func writeError(w http.ResponseWriter, status int, message string, uncertain bool) {
	writeJSON(w, status, failure{Error: message, Uncertain: uncertain})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
