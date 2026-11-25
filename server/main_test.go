package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestValidShare(t *testing.T) {
	good := []string{
		"https://pan.quark.cn/s/a1",
		"https://pan.xunlei.com/s/a1?pwd=abcd",
		"https://pan.baidu.com/s/1a1?pwd=1234",
	}
	for _, value := range good {
		if !validShare(value) {
			t.Errorf("expected accepted share URL: %s", value)
		}
	}
	bad := []string{
		"https://evil-pan.quark.cn/s/a1",
		"https://pan.quark.cn.evil.test/s/a1",
		"https://user@pan.quark.cn/s/a1",
		"https://pan.quark.cn:443/s/a1",
		"http://pan.quark.cn/s/a1",
		"https://pan.quark.cn.evil/s/a1",
		"https://pan.quark.cn/files/a1",
	}
	for _, value := range bad {
		if validShare(value) {
			t.Errorf("expected rejected share URL: %s", value)
		}
	}
}

func TestLedgerPersistsIdempotencyResults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "transfers.json")
	store, err := loadLedger(path)
	if err != nil {
		t.Fatal(err)
	}
	want := record{ShareURL: "https://pan.quark.cn/s/new", Code: "a1", Title: "example"}
	if err := store.put("job-1", want); err != nil {
		t.Fatal(err)
	}
	reloaded, err := loadLedger(path)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := reloaded.get("job-1")
	if !ok || got != want {
		t.Fatalf("ledger result = %#v, %v; want %#v", got, ok, want)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0077 != 0 {
		t.Errorf("ledger permissions are too broad: %o", info.Mode().Perm())
	}
}

func TestAuthorizationUsesBearer(t *testing.T) {
	for _, tc := range []struct {
		auth string
		want int
	}{
		{"", 401}, {"Basic secret", 401}, {"Bearer wrong", 401}, {"Bearer 0123456789abcdef0123456789abcdef", 200},
	} {
		r := httptest.NewRequest("GET", "/", nil)
		if tc.auth != "" {
			r.Header.Set("Authorization", tc.auth)
		}
		w := httptest.NewRecorder()
		if ok := authorized(w, r, "0123456789abcdef0123456789abcdef"); ok != (tc.want == 200) {
			t.Errorf("authorized(%q) = %v", tc.auth, ok)
		}
		if w.Code != tc.want {
			t.Errorf("status = %d; want %d", w.Code, tc.want)
		}
		if tc.want == 401 {
			var body failure
			if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || body.Error == "" {
				t.Fatalf("invalid auth response: %s", w.Body.String())
			}
		}
	}
}
