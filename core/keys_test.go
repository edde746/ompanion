package core

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

type generatedKey struct {
	PrivateKey  string `json:"privateKey"`
	PublicKey   string `json:"publicKey"`
	Fingerprint string `json:"fingerprint"`
}

type inspectedKey struct {
	Type        string `json:"type"`
	PublicKey   string `json:"publicKey"`
	Fingerprint string `json:"fingerprint"`
	Comment     string `json:"comment"`
	Encrypted   bool   `json:"encrypted"`
}

func TestKeys(t *testing.T) {
	h := newHarness(t)
	for _, tc := range []struct {
		params map[string]any
		want   string
	}{
		{map[string]any{"type": "ed25519"}, "ssh-ed25519"},
		{map[string]any{"type": "rsa"}, "ssh-rsa"},
		{map[string]any{"type": "ecdsa"}, "ecdsa-sha2-nistp256"},
		{map[string]any{"type": "ecdsa", "bits": 384}, "ecdsa-sha2-nistp384"},
		{map[string]any{"type": "ecdsa", "bits": 521}, "ecdsa-sha2-nistp521"},
	} {
		for _, passphrase := range []string{"", "pässphrase"} {
			params := map[string]any{"comment": "me@ompanion", "passphrase": passphrase}
			for key, value := range tc.params {
				params[key] = value
			}
			generated := okInto[generatedKey](h, "keys.generate", params)
			public, comment, _, _, err := ssh.ParseAuthorizedKey([]byte(generated.PublicKey))
			if err != nil || public.Type() != tc.want || comment != "me@ompanion" ||
				ssh.FingerprintSHA256(public) != generated.Fingerprint || !strings.HasPrefix(generated.Fingerprint, "SHA256:") ||
				!strings.HasPrefix(generated.PrivateKey, "-----BEGIN OPENSSH PRIVATE KEY-----") {
				t.Fatalf("keys.generate %v: %+v (%v)", params, generated, err)
			}
			if tc.want == "ssh-rsa" && len(public.Marshal()) < 384 {
				t.Fatalf("an RSA key of %d bytes is shorter than 3072 bits", len(public.Marshal()))
			}
			inspected := okInto[inspectedKey](h, "keys.inspect", map[string]string{"privateKey": generated.PrivateKey,
				"passphrase": passphrase})
			if inspected != (inspectedKey{tc.want, generated.PublicKey, generated.Fingerprint, "me@ompanion", passphrase != ""}) {
				t.Fatalf("keys.inspect of %v: %+v", params, inspected)
			}
			if passphrase != "" {
				h.fails("keys.inspect", map[string]string{"privateKey": generated.PrivateKey}, "passphrase")
				h.fails("keys.inspect", map[string]string{"privateKey": generated.PrivateKey, "passphrase": "wrong"},
					"passphrase")
			}
		}
	}
	h.fails("keys.inspect", map[string]string{"privateKey": "not a key"}, "malformed")
	h.fails("keys.inspect", map[string]string{"privateKey": "-----BEGIN FOO PRIVATE KEY-----\nAAAA\n-----END FOO PRIVATE KEY-----\n"},
		"unsupported")
	h.fails("keys.generate", map[string]any{"type": "rsa", "bits": 1024}, "")
}

// TestKeysWithOpenSSH checks that ssh-keygen reads the keys the core writes and the core reads the ones it writes.
func TestKeysWithOpenSSH(t *testing.T) {
	keygen, err := exec.LookPath("ssh-keygen")
	if err != nil {
		t.Skip("no ssh-keygen")
	}
	h := newHarness(t)
	dir := t.TempDir()
	for _, kind := range []string{"ed25519", "rsa", "ecdsa"} {
		generated := okInto[generatedKey](h, "keys.generate", map[string]string{"type": kind, "comment": "core", "passphrase": "pw"})
		path := filepath.Join(dir, "core_"+kind)
		if err := os.WriteFile(path, []byte(generated.PrivateKey), 0o600); err != nil {
			t.Fatal(err)
		}
		out, err := exec.Command(keygen, "-y", "-P", "pw", "-f", path).Output()
		if err != nil || !strings.HasPrefix(generated.PublicKey, strings.TrimSpace(string(out))) {
			t.Fatalf("ssh-keygen -y of the core's %s key: %q (%v), want %q", kind, out, err, generated.PublicKey)
		}

		path = filepath.Join(dir, "keygen_"+kind)
		if out, err := exec.Command(keygen, "-q", "-t", kind, "-N", "secret", "-C", "made by ssh-keygen", "-f", path).CombinedOutput(); err != nil {
			t.Fatalf("ssh-keygen: %s", out)
		}
		private, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		public, err := os.ReadFile(path + ".pub")
		if err != nil {
			t.Fatal(err)
		}
		inspected := okInto[inspectedKey](h, "keys.inspect", map[string]string{"privateKey": string(private), "passphrase": "secret"})
		if inspected.PublicKey != strings.TrimSpace(string(public)) || inspected.Comment != "made by ssh-keygen" || !inspected.Encrypted {
			t.Fatalf("keys.inspect of ssh-keygen's %s key: %+v, want %q", kind, inspected, public)
		}
	}
}
