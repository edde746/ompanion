package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
)

// appName names the app's own directories where the OS defaults apply.
const appName = "com.edde746.ompanion"

// appDirs returns the app's data and cache directories, created: $OMPCORE_DATA_DIR and $OMPCORE_CACHE_DIR, which
// the shells set, else the OS defaults. They are read on every call because a shell may set them after the library
// loaded.
func appDirs() (data, cache string, err error) {
	data = os.Getenv("OMPCORE_DATA_DIR")
	if data == "" {
		base, err := dataHome()
		if err != nil {
			return "", "", fmt.Errorf("no data directory: %w", err)
		}
		data = filepath.Join(base, appName)
	}
	cache = os.Getenv("OMPCORE_CACHE_DIR")
	if cache == "" {
		base, err := os.UserCacheDir()
		if err != nil {
			return "", "", fmt.Errorf("no cache directory: %w", err)
		}
		cache = filepath.Join(base, appName)
	}
	for _, dir := range []string{data, cache} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return "", "", err
		}
	}
	return data, cache, nil
}

// dataHome is where apps keep their data: Application Support on Apple, AppData\Roaming on Windows, XDG's data
// home on Linux.
func dataHome() (string, error) {
	if runtime.GOOS != "linux" {
		return os.UserConfigDir()
	}
	if dir := os.Getenv("XDG_DATA_HOME"); dir != "" {
		return dir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share"), nil
}

// CacheDir is the directory the shells serve as cache/: fs.download and net.fetch write there.
func CacheDir() (string, error) {
	_, cache, err := appDirs()
	return cache, err
}

func (c *Core) corePaths() (any, error) {
	data, cache, err := appDirs()
	if err != nil {
		return nil, err
	}
	result := map[string]string{"data": sftpPath(data), "cache": sftpPath(cache)}
	if local() {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		result["home"] = sftpPath(home)
	}
	return result, nil
}

// nativePath turns a path in SFTP path space into this OS's form.
func nativePath(path string) string { return fromSFTPPath(path, runtime.GOOS == "windows") }

// sftpPath turns a path of this OS into SFTP path space.
func sftpPath(native string) string { return toSFTPPath(native, runtime.GOOS == "windows") }

var drivePath = regexp.MustCompile(`^/[A-Za-z]:(/|$)`)

// fromSFTPPath turns /C:/x into C:\x on Windows; POSIX paths are already native.
func fromSFTPPath(path string, windows bool) string {
	if !windows {
		return path
	}
	if drivePath.MatchString(path) {
		path = path[1:]
		if len(path) == 2 {
			path += "/"
		}
	}
	return strings.ReplaceAll(path, "/", `\`)
}

// toSFTPPath turns C:\x into /C:/x on Windows; POSIX paths are already in SFTP path space.
func toSFTPPath(native string, windows bool) string {
	if !windows {
		return native
	}
	path := strings.ReplaceAll(native, `\`, "/")
	if drivePath.MatchString("/" + path) {
		return "/" + path
	}
	return path
}

// writeAtomic replaces path with what r yields, through a temporary file next to it, so a reader sees the old
// content or the new, never a part.
func writeAtomic(path string, r io.Reader) (int64, error) {
	temp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(temp, r)
	if err == nil {
		err = temp.Sync()
	}
	err = errors.Join(err, temp.Close())
	if err == nil {
		err = os.Rename(temp.Name(), path)
	}
	if err != nil {
		return 0, errors.Join(err, os.Remove(temp.Name()))
	}
	return n, nil
}

var storeName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$`)

// storeMu serialises the store's requests: Windows refuses to rename a document over one that another request is
// reading or renaming over at the same time.
var storeMu sync.Mutex

// storePath is where the store document name lives: <data>/store/<name>.json.
func storePath(name string) (string, error) {
	if !storeName.MatchString(name) {
		return "", fmt.Errorf("bad store name %q: use letters, digits, '_', '.' and '-'", name)
	}
	data, _, err := appDirs()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(data, "store")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return filepath.Join(dir, name+".json"), nil
}

type storeParams struct {
	Name string `json:"name"`
}

func storeRead(params json.RawMessage) (any, error) {
	p, err := decode[storeParams](params)
	if err != nil {
		return nil, err
	}
	storeMu.Lock()
	defer storeMu.Unlock()
	path, err := storePath(p.Name)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]any{"text": nil}, nil
	}
	if err != nil {
		return nil, err
	}
	return map[string]string{"text": string(data)}, nil
}

func storeWrite(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		Name string  `json:"name"`
		Text *string `json:"text"`
	}](params)
	if err != nil {
		return nil, err
	}
	if p.Text == nil {
		return nil, errors.New("store.write needs text")
	}
	storeMu.Lock()
	defer storeMu.Unlock()
	path, err := storePath(p.Name)
	if err != nil {
		return nil, err
	}
	if _, err := writeAtomic(path, strings.NewReader(*p.Text)); err != nil {
		return nil, err
	}
	return struct{}{}, nil
}

func storeDelete(params json.RawMessage) (any, error) {
	p, err := decode[storeParams](params)
	if err != nil {
		return nil, err
	}
	storeMu.Lock()
	defer storeMu.Unlock()
	path, err := storePath(p.Name)
	if err != nil {
		return nil, err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	return struct{}{}, nil
}
