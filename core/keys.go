package core

import (
	"crypto"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha512"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"golang.org/x/crypto/blowfish"
	"golang.org/x/crypto/ssh"
)

func keysGenerate(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		Type       string `json:"type"`
		Bits       int    `json:"bits"`
		Comment    string `json:"comment"`
		Passphrase string `json:"passphrase"`
	}](params)
	if err != nil {
		return nil, err
	}
	var key crypto.Signer
	switch p.Type {
	case "ed25519":
		if p.Bits != 0 {
			return nil, errors.New("ed25519 keys have no bits")
		}
		_, key, err = ed25519.GenerateKey(rand.Reader)
	case "rsa":
		bits := p.Bits
		if bits == 0 {
			bits = 3072 // ssh-keygen's default
		}
		if bits < 2048 {
			return nil, fmt.Errorf("an RSA key needs at least 2048 bits, not %d", bits)
		}
		key, err = rsa.GenerateKey(rand.Reader, bits)
	case "ecdsa":
		var curve elliptic.Curve
		switch p.Bits {
		case 0, 256:
			curve = elliptic.P256()
		case 384:
			curve = elliptic.P384()
		case 521:
			curve = elliptic.P521()
		default:
			return nil, fmt.Errorf("an ECDSA key has 256, 384 or 521 bits, not %d", p.Bits)
		}
		key, err = ecdsa.GenerateKey(curve, rand.Reader)
	default:
		return nil, fmt.Errorf("unknown key type %q: use ed25519, rsa or ecdsa", p.Type)
	}
	if err != nil {
		return nil, err
	}
	var block *pem.Block
	if p.Passphrase != "" {
		block, err = ssh.MarshalPrivateKeyWithPassphrase(key, p.Comment, []byte(p.Passphrase))
	} else {
		block, err = ssh.MarshalPrivateKey(key, p.Comment)
	}
	if err != nil {
		return nil, err
	}
	public, err := ssh.NewPublicKey(key.Public())
	if err != nil {
		return nil, err
	}
	return map[string]string{
		"privateKey":  string(pem.EncodeToMemory(block)),
		"publicKey":   authorizedKey(public, p.Comment),
		"fingerprint": ssh.FingerprintSHA256(public),
	}, nil
}

func keysInspect(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		PrivateKey string `json:"privateKey"`
		Passphrase string `json:"passphrase"`
	}](params)
	if err != nil {
		return nil, err
	}
	signer, encrypted, err := parsePrivateKey([]byte(p.PrivateKey), p.Passphrase)
	if err != nil {
		return nil, err
	}
	comment, err := openSSHComment([]byte(p.PrivateKey), p.Passphrase)
	if err != nil {
		return nil, err
	}
	public := signer.PublicKey()
	return map[string]any{
		"type":        public.Type(),
		"publicKey":   authorizedKey(public, comment),
		"fingerprint": ssh.FingerprintSHA256(public),
		"comment":     comment,
		"encrypted":   encrypted,
	}, nil
}

// parsePrivateKey reads an OpenSSH or PEM private key, decrypting it with passphrase when it is encrypted; a
// passphrase for a key that is not encrypted is ignored. Errors carry code "passphrase" (missing or wrong),
// "unsupported" or "malformed".
func parsePrivateKey(pemBytes []byte, passphrase string) (signer ssh.Signer, encrypted bool, err error) {
	signer, err = ssh.ParsePrivateKey(pemBytes)
	var missing *ssh.PassphraseMissingError
	if !errors.As(err, &missing) {
		if err != nil {
			return nil, false, keyProblem(err)
		}
		return signer, false, nil
	}
	if passphrase == "" {
		return nil, true, withCode("passphrase", errors.New("the private key is encrypted: it needs its passphrase"))
	}
	signer, err = ssh.ParsePrivateKeyWithPassphrase(pemBytes, []byte(passphrase))
	if errors.Is(err, x509.IncorrectPasswordError) {
		return nil, true, withCode("passphrase", errors.New("wrong passphrase for the private key"))
	}
	if err != nil {
		return nil, true, keyProblem(err)
	}
	return signer, true, nil
}

// keyProblem tells a key x/crypto cannot use (another type, an unknown cipher or curve) from a damaged one; its
// errors have no types to tell them by.
func keyProblem(err error) error {
	message := err.Error()
	if strings.Contains(message, "unsupported") || strings.Contains(message, "unhandled") ||
		strings.Contains(message, "unknown") || strings.Contains(message, "not supported") {
		return withCode("unsupported", fmt.Errorf("unsupported private key: %w", err))
	}
	return withCode("malformed", fmt.Errorf("not a private key: %w", err))
}

// authorizedKey is public's authorized_keys line, with comment when there is one.
func authorizedKey(public ssh.PublicKey, comment string) string {
	line := strings.TrimSuffix(string(ssh.MarshalAuthorizedKey(public)), "\n")
	if comment != "" {
		line += " " + comment
	}
	return line
}

const openSSHMagic = "openssh-key-v1\x00"

// openSSHComment returns the comment of an OpenSSH private key, which x/crypto reads but does not return
// (PROTOCOL.key); other formats have none. The key has already been checked to open with passphrase.
func openSSHComment(pemBytes []byte, passphrase string) (string, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil || block.Type != "OPENSSH PRIVATE KEY" {
		return "", nil
	}
	var container struct {
		CipherName   string
		KdfName      string
		KdfOpts      string
		NumKeys      uint32
		PubKey       []byte
		PrivKeyBlock []byte
		Rest         []byte `ssh:"rest"`
	}
	if !strings.HasPrefix(string(block.Bytes), openSSHMagic) {
		return "", errors.New("not an OpenSSH private key")
	}
	if err := ssh.Unmarshal(block.Bytes[len(openSSHMagic):], &container); err != nil {
		return "", err
	}
	private := container.PrivKeyBlock
	if container.CipherName != "none" {
		var opts struct {
			Salt   []byte
			Rounds uint32
		}
		if err := ssh.Unmarshal([]byte(container.KdfOpts), &opts); err != nil {
			return "", err
		}
		key := bcryptPBKDF([]byte(passphrase), opts.Salt, int(opts.Rounds), 32+16)
		c, err := aes.NewCipher(key[:32])
		if err != nil {
			return "", err
		}
		switch container.CipherName {
		case "aes256-ctr":
			cipher.NewCTR(c, key[32:]).XORKeyStream(private, private)
		case "aes256-cbc":
			cipher.NewCBCDecrypter(c, key[32:]).CryptBlocks(private, private)
		default:
			return "", fmt.Errorf("unknown cipher %q", container.CipherName)
		}
	}
	var keys struct {
		Check1, Check2 uint32
		KeyType        string
		Rest           []byte `ssh:"rest"`
	}
	if err := ssh.Unmarshal(private, &keys); err != nil {
		return "", err
	}
	var target any
	var comment *string
	switch {
	case keys.KeyType == ssh.KeyAlgoED25519:
		key := &struct {
			Pub, Priv []byte
			Comment   string
			Pad       []byte `ssh:"rest"`
		}{}
		target, comment = key, &key.Comment
	case keys.KeyType == ssh.KeyAlgoRSA:
		key := &struct {
			N, E, D, Iqmp, P, Q *big.Int
			Comment             string
			Pad                 []byte `ssh:"rest"`
		}{}
		target, comment = key, &key.Comment
	case strings.HasPrefix(keys.KeyType, "ecdsa-sha2-"):
		key := &struct {
			Curve   string
			Pub     []byte
			D       *big.Int
			Comment string
			Pad     []byte `ssh:"rest"`
		}{}
		target, comment = key, &key.Comment
	default:
		return "", fmt.Errorf("unsupported key type %q", keys.KeyType)
	}
	if err := ssh.Unmarshal(keys.Rest, target); err != nil {
		return "", err
	}
	return *comment, nil
}

// bcryptPBKDF is OpenBSD's bcrypt_pbkdf(3), which OpenSSH derives a private key's cipher key with; as x/crypto's
// internal copy (golang.org/x/crypto/ssh/internal/bcrypt_pbkdf, BSD licence), which a package outside x/crypto cannot
// import.
func bcryptPBKDF(password, salt []byte, rounds, keyLen int) []byte {
	const blockSize = 32
	numBlocks := (keyLen + blockSize - 1) / blockSize
	key := make([]byte, numBlocks*blockSize)
	h := sha512.New()
	h.Write(password)
	shapass := h.Sum(nil)
	shasalt := make([]byte, 0, sha512.Size)
	cnt, tmp := make([]byte, 4), make([]byte, blockSize)
	for block := 1; block <= numBlocks; block++ {
		h.Reset()
		h.Write(salt)
		cnt[0], cnt[1], cnt[2], cnt[3] = byte(block>>24), byte(block>>16), byte(block>>8), byte(block)
		h.Write(cnt)
		bcryptHash(tmp, shapass, h.Sum(shasalt))
		out := make([]byte, blockSize)
		copy(out, tmp)
		for i := 2; i <= rounds; i++ {
			h.Reset()
			h.Write(tmp)
			bcryptHash(tmp, shapass, h.Sum(shasalt))
			for j := range out {
				out[j] ^= tmp[j]
			}
		}
		for i, v := range out {
			key[i*numBlocks+(block-1)] = v
		}
	}
	return key[:keyLen]
}

func bcryptHash(out, shapass, shasalt []byte) {
	c, err := blowfish.NewSaltedCipher(shapass, shasalt)
	if err != nil {
		panic(err) // NewSaltedCipher fails only for an empty key; shapass is a SHA-512 sum
	}
	for range 64 {
		blowfish.ExpandKey(shasalt, c)
		blowfish.ExpandKey(shapass, c)
	}
	copy(out, "OxychromaticBlowfishSwatDynamite")
	for i := 0; i < 32; i += 8 {
		for range 64 {
			c.Encrypt(out[i:i+8], out[i:i+8])
		}
	}
	// Swap bytes due to different endianness.
	for i := 0; i < 32; i += 4 {
		out[i+3], out[i+2], out[i+1], out[i] = out[i], out[i+1], out[i+2], out[i+3]
	}
}
