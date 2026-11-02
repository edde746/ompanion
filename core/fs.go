package core

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/pkg/sftp"
)

// fileSystem is what fs.* needs of a machine's files: this device's, or an SSH machine's over SFTP. Paths are in
// SFTP path space.
type fileSystem interface {
	stat(path string, followLinks bool) (fs.FileInfo, error)
	// readDir describes entries without following links, without "." and "..".
	readDir(path string) ([]fs.FileInfo, error)
	open(path string, flag int) (file, error)
	chmod(path string, mode fs.FileMode) error
	// chtimes sets the access and modification times.
	chtimes(path string, modified time.Time) error
	mkdir(path string) error
	remove(path string) error
	removeDir(path string) error
	rename(from, to string) error
	home() (string, error)
}

// file is what *os.File and *sftp.File both are.
type file interface {
	io.Reader
	io.ReaderAt
	io.Writer
	io.Seeker
	io.Closer
	Stat() (fs.FileInfo, error)
	Chmod(mode fs.FileMode) error
}

type fsParams struct {
	Machine     string  `json:"machine"`
	Path        string  `json:"path"`
	FollowLinks *bool   `json:"followLinks"`
	Offset      int64   `json:"offset"`
	Length      *int64  `json:"length"`
	Data        string  `json:"data"`
	Append      bool    `json:"append"`
	Mode        *uint32 `json:"mode"`
	From        string  `json:"from"`
	To          string  `json:"to"`
	ModifiedMs  *int64  `json:"modifiedMs"`
	Cache       string  `json:"cache"`
}

// fs runs one fs.* method.
func (c *Core) fs(method string, params json.RawMessage) (any, error) {
	p, err := decode[fsParams](params)
	if err != nil {
		return nil, err
	}
	files, label, key, err := c.files(p.Machine)
	if err != nil {
		return nil, err
	}
	failed := func(action, path string, err error) error {
		message := fmt.Errorf("%s: %s %s: %w", label, action, path, err)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			return withCode("missing", message)
		case errors.Is(err, fs.ErrExist):
			return withCode("exists", message)
		default:
			return message
		}
	}
	if method != "fs.home" && method != "fs.rename" && p.Path == "" {
		return nil, fmt.Errorf("%s needs path", method)
	}
	switch method {
	case "fs.home":
		home, err := files.home()
		if err != nil {
			return nil, failed("realpath", ".", err)
		}
		return map[string]string{"path": home}, nil
	case "fs.stat":
		info, err := files.stat(p.Path, p.FollowLinks == nil || *p.FollowLinks)
		if errors.Is(err, fs.ErrNotExist) {
			return map[string]any{"stat": nil}, nil
		}
		if err != nil {
			return nil, failed("stat", p.Path, err)
		}
		return map[string]any{"stat": fileStat(info)}, nil
	case "fs.list":
		infos, err := files.readDir(p.Path)
		if err != nil {
			return nil, failed("list", p.Path, err)
		}
		entries := make([]map[string]any, len(infos))
		for i, info := range infos {
			entries[i] = map[string]any{"name": info.Name(), "stat": fileStat(info)}
		}
		return map[string]any{"entries": entries}, nil
	case "fs.read":
		data, err := readFile(files, p.Path, p.Offset, p.Length)
		if err != nil {
			return nil, failed("read", p.Path, err)
		}
		return map[string]string{"data": base64.StdEncoding.EncodeToString(data)}, nil
	case "fs.write":
		data, err := base64.StdEncoding.DecodeString(p.Data)
		if err != nil {
			return nil, fmt.Errorf("fs.write takes base64 data: %w", err)
		}
		if _, err := writeFile(files, p.Path, bytes.NewReader(data), p.Append, p.Mode); err != nil {
			return nil, failed("write", p.Path, err)
		}
		return struct{}{}, nil
	case "fs.mkdir":
		// A lock holder may remove the directory between a failed mkdir and the check: try once more.
		for attempt := 1; ; attempt++ {
			err := files.mkdir(p.Path)
			if err == nil {
				break
			}
			// SFTPv3 has no "already exists" status: OpenSSH reports EEXIST as a generic failure.
			if _, statErr := files.stat(p.Path, false); errors.Is(err, fs.ErrExist) || statErr == nil {
				return nil, withCode("exists", fmt.Errorf("already exists: %s", p.Path))
			}
			if attempt == 2 {
				return nil, failed("mkdir", p.Path, err)
			}
		}
		if p.Mode != nil {
			if err := files.chmod(p.Path, fs.FileMode(*p.Mode).Perm()); err != nil {
				return nil, failed("chmod", p.Path, err)
			}
		}
		return struct{}{}, nil
	case "fs.remove":
		if err := files.remove(p.Path); err != nil {
			return nil, failed("remove", p.Path, err)
		}
		return struct{}{}, nil
	case "fs.removeDir":
		if err := files.removeDir(p.Path); err != nil {
			return nil, failed("rmdir", p.Path, err)
		}
		return struct{}{}, nil
	case "fs.rename":
		if p.From == "" || p.To == "" {
			return nil, errors.New("fs.rename needs from and to")
		}
		if err := files.rename(p.From, p.To); err != nil {
			return nil, failed("rename", p.From+" -> "+p.To, err)
		}
		return struct{}{}, nil
	case "fs.touch":
		if p.ModifiedMs == nil {
			return nil, errors.New("fs.touch needs modifiedMs")
		}
		if err := files.chtimes(p.Path, time.UnixMilli(*p.ModifiedMs)); err != nil {
			return nil, failed("touch", p.Path, err)
		}
		return struct{}{}, nil
	case "fs.download":
		name, size, err := download(files, key, p.Path)
		if err != nil {
			return nil, failed("download", p.Path, err)
		}
		return map[string]any{"url": "cache/" + name, "size": size}, nil
	case "fs.upload":
		cached, err := openCached(p.Cache)
		if err != nil {
			return nil, err
		}
		defer cached.Close()
		size, err := writeFile(files, p.Path, cached, false, p.Mode)
		if err != nil {
			return nil, failed("upload", p.Path, err)
		}
		return map[string]any{"size": size}, nil
	}
	return nil, fmt.Errorf("unknown method %q", method)
}

// files returns the files of machine, the label its errors carry, and the key that tells it from every other machine
// in names of downloaded files: every hop, so one host reached through different jump hosts gets its own.
func (c *Core) files(machine string) (files fileSystem, label, key string, err error) {
	if machine == "local" {
		return localFiles{}, "this computer", "local", nil
	}
	m, err := c.machine(machine)
	if err != nil {
		return nil, "", "", err
	}
	if files, err = m.files(); err != nil {
		return nil, "", "", err
	}
	return files, m.label, m.key, nil
}

// fileStat is a stat as docs/contracts/bridge.md describes it; mode is POSIX st_mode, file type bits included, as SFTP
// carries it.
func fileStat(info fs.FileInfo) map[string]any {
	stat := map[string]any{
		"size":        info.Size(),
		"isDirectory": info.IsDir(),
		"isLink":      info.Mode()&fs.ModeSymlink != 0,
		"mode":        unixMode(info.Mode()),
	}
	if modified := info.ModTime(); !modified.IsZero() {
		stat["modifiedMs"] = modified.UnixMilli()
	}
	return stat
}

func unixMode(mode fs.FileMode) uint32 {
	bits := uint32(mode.Perm())
	switch {
	case mode.IsDir():
		bits |= 0o040000
	case mode&fs.ModeSymlink != 0:
		bits |= 0o120000
	case mode&fs.ModeNamedPipe != 0:
		bits |= 0o010000
	case mode&fs.ModeSocket != 0:
		bits |= 0o140000
	case mode&fs.ModeCharDevice != 0:
		bits |= 0o020000
	case mode&fs.ModeDevice != 0:
		bits |= 0o060000
	default:
		bits |= 0o100000
	}
	if mode&fs.ModeSetuid != 0 {
		bits |= 0o4000
	}
	if mode&fs.ModeSetgid != 0 {
		bits |= 0o2000
	}
	if mode&fs.ModeSticky != 0 {
		bits |= 0o1000
	}
	return bits
}

// readFile reads length bytes from offset, or to the end when length is nil.
func readFile(files fileSystem, path string, offset int64, length *int64) ([]byte, error) {
	if offset < 0 || (length != nil && *length < 0) {
		return nil, errors.New("offset and length must not be negative")
	}
	f, err := files.open(path, os.O_RDONLY)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	n := max(info.Size()-offset, 0)
	if length != nil {
		n = min(n, *length)
	}
	buf := make([]byte, n)
	read, err := f.ReadAt(buf, offset)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	return buf[:read], nil
}

// writeFile creates or truncates path, or appends to it, with what r yields, and returns how many bytes it wrote; mode
// applies when it creates the file, before any byte is written, so a secret is never readable by others.
func writeFile(files fileSystem, path string, r io.Reader, appending bool, mode *uint32) (int64, error) {
	var f file
	if mode != nil {
		created, err := files.open(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL)
		switch {
		case err == nil:
			if err := created.Chmod(fs.FileMode(*mode).Perm()); err != nil {
				return 0, errors.Join(err, created.Close())
			}
			f = created
		case errors.Is(err, fs.ErrExist):
		default:
			// SFTPv3 has no "already exists" status: OpenSSH reports EEXIST as a generic failure.
			if _, statErr := files.stat(path, false); statErr != nil {
				return 0, err
			}
		}
	}
	if f == nil {
		flag := os.O_WRONLY | os.O_CREATE | os.O_TRUNC
		if appending {
			flag = os.O_WRONLY | os.O_CREATE | os.O_APPEND
		}
		opened, err := files.open(path, flag)
		if err != nil {
			return 0, err
		}
		f = opened
		// OpenSSH's sftp-server appends whatever the offset; other servers write at the offset given.
		if appending {
			if _, err := f.Seek(0, io.SeekEnd); err != nil {
				return 0, errors.Join(err, f.Close())
			}
		}
	}
	var written int64
	var err error
	if sftpFile, ok := f.(*sftp.File); ok && !appending {
		// Overlapping writes: one at a time, a large upload would wait a round trip per packet. Not when appending,
		// where OpenSSH would append them in the order they arrive.
		written, err = sftpFile.ReadFromWithConcurrency(r, 0)
	} else {
		written, err = io.Copy(f, r)
	}
	if err != nil {
		return 0, errors.Join(err, f.Close())
	}
	return written, f.Close()
}

// download copies path into the cache directory under a name that is stable for the file's machine, path, size and
// modification time, and keeps its extension.
func download(files fileSystem, machineKey, path string) (name string, size int64, err error) {
	f, err := files.open(path, os.O_RDONLY)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	key := strings.Join([]string{machineKey, path, strconv.FormatInt(info.Size(), 10),
		strconv.FormatInt(info.ModTime().UnixNano(), 10)}, "\x00")
	return toCache(key, extension(path), f)
}

// toCache writes r into the cache directory as the file named after key and ext, and returns its name there.
func toCache(key, ext string, r io.Reader) (name string, size int64, err error) {
	_, cache, err := appDirs()
	if err != nil {
		return "", 0, err
	}
	sum := sha256.Sum256([]byte(key))
	name = hex.EncodeToString(sum[:12]) + ext
	size, err = writeAtomic(filepath.Join(cache, name), r)
	if err != nil {
		return "", 0, err
	}
	return name, size, nil
}

// openCached opens the file name in the cache directory; name is a plain file name, as net.fetch returns them.
func openCached(name string) (*os.File, error) {
	if !filepath.IsLocal(name) || strings.ContainsAny(name, `/\`) {
		return nil, fmt.Errorf("%q is not a file name in the cache", name)
	}
	_, cache, err := appDirs()
	if err != nil {
		return nil, err
	}
	f, err := os.Open(filepath.Join(cache, name))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, withCode("missing", fmt.Errorf("the cache has no file %q", name))
	}
	return f, err
}

var cacheExtension = regexp.MustCompile(`^\.[a-z0-9]{1,10}$`)

// extension is the lower-case extension of path when it is a plain one, so the cache file keeps its type; else "".
func extension(p string) string {
	ext := strings.ToLower(path.Ext(p))
	if !cacheExtension.MatchString(ext) {
		return ""
	}
	return ext
}

// localFiles are this device's files.
type localFiles struct{}

func (localFiles) stat(path string, followLinks bool) (fs.FileInfo, error) {
	if followLinks {
		return os.Stat(nativePath(path))
	}
	return os.Lstat(nativePath(path))
}

func (localFiles) readDir(path string) ([]fs.FileInfo, error) {
	entries, err := os.ReadDir(nativePath(path))
	if err != nil {
		return nil, err
	}
	infos := make([]fs.FileInfo, 0, len(entries))
	for _, entry := range entries {
		info, err := entry.Info()
		if errors.Is(err, fs.ErrNotExist) {
			continue // removed since the directory was read
		}
		if err != nil {
			return nil, err
		}
		infos = append(infos, info)
	}
	return infos, nil
}

func (localFiles) open(path string, flag int) (file, error) {
	return os.OpenFile(nativePath(path), flag, 0o666)
}

func (localFiles) chmod(path string, mode fs.FileMode) error { return os.Chmod(nativePath(path), mode) }

func (localFiles) chtimes(path string, modified time.Time) error {
	return os.Chtimes(nativePath(path), modified, modified)
}

func (localFiles) mkdir(path string) error     { return os.Mkdir(nativePath(path), 0o777) }
func (localFiles) remove(path string) error    { return os.Remove(nativePath(path)) }
func (localFiles) removeDir(path string) error { return os.Remove(nativePath(path)) }

// rename replaces an existing target, as posix-rename@openssh.com does.
func (localFiles) rename(from, to string) error { return os.Rename(nativePath(from), nativePath(to)) }

func (localFiles) home() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return sftpPath(home), nil
}

// sftpFiles are an SSH machine's files.
type sftpFiles struct{ client *sftp.Client }

func (s sftpFiles) stat(path string, followLinks bool) (fs.FileInfo, error) {
	if followLinks {
		return s.client.Stat(path)
	}
	return s.client.Lstat(path)
}

// readDir relies on OpenSSH's sftp-server describing READDIR entries with lstat, so links arrive as links.
func (s sftpFiles) readDir(path string) ([]fs.FileInfo, error) { return s.client.ReadDir(path) }

func (s sftpFiles) open(path string, flag int) (file, error) { return s.client.OpenFile(path, flag) }

func (s sftpFiles) chmod(path string, mode fs.FileMode) error { return s.client.Chmod(path, mode) }

func (s sftpFiles) chtimes(path string, modified time.Time) error {
	return s.client.Chtimes(path, modified, modified)
}

func (s sftpFiles) mkdir(path string) error     { return s.client.Mkdir(path) }
func (s sftpFiles) remove(path string) error    { return s.client.Remove(path) }
func (s sftpFiles) removeDir(path string) error { return s.client.RemoveDirectory(path) }

// rename replaces an existing target with posix-rename@openssh.com when the server has it; plain SFTP rename
// refuses an existing target.
func (s sftpFiles) rename(from, to string) error {
	if _, ok := s.client.HasExtension("posix-rename@openssh.com"); ok {
		return s.client.PosixRename(from, to)
	}
	return s.client.Rename(from, to)
}

func (s sftpFiles) home() (string, error) { return s.client.RealPath(".") }
