// Command licenses completes the licences page's list (ui/src/app/screens/settings/licenses_page.tsx) for one shell's
// build: to the page's own `licenses.json`, which `vite build` writes with the npm packages it bundles (the group
// `page`), it adds the group `core` (the Go standard library and every module linked into the core, from `go list
// -deps` and each module's licence file in the module cache) and the group `platform` (the shell's native libraries,
// from their fetched packages). Each shell's build script runs it from core/ on the copy of the page it bundles:
//
//	go run ./cmd/licenses -ui <page dir> -target <platform>... [inputs]
//
// -target names a platform the page ships in (macos, ios, android, linux, windows; the Apple shells share one page,
// so they name two); a package only some of them link is marked with those. Inputs, each optional:
//
//	-swiftpm <dir> -xcodegen <project.yml>  Swift packages: the products each target of project.yml links, followed
//	                                        through `swift package dump-package` to the packages they need, from the
//	                                        SourcePackages directory xcodebuild resolved them into
//	-maven <file>                           Maven libraries: the list shells/android's `licenseInputs` task writes
//	-nuget <dir>                            an unpacked NuGet package (its .nuspec and licence file)
//	-notice <name>[@<version>]=<file>       one more licence file, such as a toolchain's statically linked runtime's
//	-texts <dir>                            licence files for libraries that ship without one: <dir>/<name>.txt,
//	                                        with a Maven library's `group:artifact` as `group/artifact`
//
// It fails on a library with no licence text and on GPL-family code: neither may ship (docs/research/licenses.md).
package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	_ "embed"
	"encoding/json"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"maps"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// The Apache License 2.0 as apache.org publishes it (LICENSE-2.0.txt): the text of the Maven libraries whose POM
// names that licence and whose package carries no copy.
//
//go:embed apache-2.0.txt
var apacheLicense string

// The groups this command writes; it replaces them when it runs on a page again.
const (
	coreGroup     = "core"
	platformGroup = "platform"
)

// What each platform's core is built from: gomobile binds ./ompcore for the Apple and Android shells and links its
// own Go runtime package, bind/seq, into it (core/scripts/bind-*.sh); the desktop shells link the C binding ./capi
// (shells/{linux,windows}/build.sh). The architecture changes no module, so arm64 stands for every one.
var goBuilds = map[string]struct {
	goos     string
	packages []string
}{
	"macos":   {"darwin", []string{"./ompcore", "golang.org/x/mobile/bind/seq"}},
	"ios":     {"ios", []string{"./ompcore", "golang.org/x/mobile/bind/seq"}},
	"android": {"android", []string{"./ompcore", "golang.org/x/mobile/bind/seq"}},
	"linux":   {"linux", []string{"./capi"}},
	"windows": {"windows", []string{"./capi"}},
}

// A package's licence as the page lists it.
type entry struct {
	name, version, license, text string
}

type list []string

func (l *list) String() string     { return strings.Join(*l, ",") }
func (l *list) Set(v string) error { *l = append(*l, v); return nil }

func main() {
	log.SetFlags(0)
	log.SetPrefix("licenses: ")
	ui := flag.String("ui", "", "the page's directory, holding licenses.json")
	swiftpm := flag.String("swiftpm", "", "xcodebuild's SourcePackages directory")
	xcodegen := flag.String("xcodegen", "", "the XcodeGen project.yml naming the Swift package products")
	maven := flag.String("maven", "", "the Maven library list")
	nuget := flag.String("nuget", "", "an unpacked NuGet package")
	texts := flag.String("texts", "", "licence files for libraries that ship without one")
	var targets, notices list
	flag.Var(&targets, "target", "a platform the page ships in (repeatable)")
	flag.Var(&notices, "notice", "<name>[@<version>]=<file> (repeatable)")
	flag.Parse()
	if *ui == "" || len(targets) == 0 || flag.NArg() > 0 || (*swiftpm == "") != (*xcodegen == "") {
		flag.Usage()
		os.Exit(2)
	}
	found := newFound(targets)
	for _, platform := range targets {
		entries, err := goEntries(platform)
		if err != nil {
			log.Fatal(err)
		}
		found.add(coreGroup, platform, entries)
	}
	if *swiftpm != "" {
		byPlatform, err := swiftEntries(*swiftpm, *xcodegen, targets)
		if err != nil {
			log.Fatal(err)
		}
		for _, platform := range targets {
			found.add(platformGroup, platform, byPlatform[platform])
		}
	}
	if *maven != "" {
		entries, err := mavenEntries(*maven, *texts)
		if err != nil {
			log.Fatal(err)
		}
		found.addAll(platformGroup, entries)
	}
	if *nuget != "" {
		e, err := nugetEntry(*nuget)
		if err != nil {
			log.Fatal(err)
		}
		found.addAll(platformGroup, []entry{e})
	}
	for _, notice := range notices {
		e, err := noticeEntry(notice)
		if err != nil {
			log.Fatal(err)
		}
		found.addAll(platformGroup, []entry{e})
	}
	if err := found.check(); err != nil {
		log.Fatal(err)
	}
	if err := found.write(filepath.Join(*ui, "licenses.json")); err != nil {
		log.Fatal(err)
	}
}

// found collects entries by group, with the platforms each one ships in.
type found struct {
	targets []string
	groups  map[string]map[entry][]string
}

func newFound(targets []string) *found {
	return &found{targets: targets, groups: map[string]map[entry][]string{}}
}

func (f *found) add(group, platform string, entries []entry) {
	if f.groups[group] == nil {
		f.groups[group] = map[entry][]string{}
	}
	for _, e := range entries {
		if !slices.Contains(f.groups[group][e], platform) {
			f.groups[group][e] = append(f.groups[group][e], platform)
		}
	}
}

func (f *found) addAll(group string, entries []entry) {
	for _, platform := range f.targets {
		f.add(group, platform, entries)
	}
}

var copyleft = regexp.MustCompile(`^(A|L)?GPL`)

func (f *found) check() error {
	var problems []string
	for _, entries := range f.groups {
		for e := range entries {
			if strings.TrimSpace(e.text) == "" {
				problems = append(problems, fmt.Sprintf("%s %s has no licence text", e.name, e.version))
			} else if copyleft.MatchString(e.license) {
				problems = append(problems, fmt.Sprintf("%s %s is %s", e.name, e.version, e.license))
			}
		}
	}
	if len(problems) > 0 {
		slices.Sort(problems)
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

// The licences page's file: every distinct licence text once, in `texts`, and each package naming its text by index.
type licensesFile struct {
	Texts  []string    `json:"texts"`
	Groups []fileGroup `json:"groups"`
}

type fileGroup struct {
	ID       string        `json:"id"`
	Packages []filePackage `json:"packages"`
}

type filePackage struct {
	Name      string   `json:"name"`
	Version   string   `json:"version"`
	License   string   `json:"license"`
	Text      int      `json:"text"`
	Platforms []string `json:"platforms,omitempty"`
}

// write keeps the page's other groups and replaces this command's.
func (f *found) write(file string) error {
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	var old licensesFile
	if err := json.Unmarshal(data, &old); err != nil {
		return fmt.Errorf("%s: %w", file, err)
	}
	if len(old.Groups) == 0 {
		return fmt.Errorf("%s has no groups: the page is from before the licence groups; build it again (cd ui && bun run build)", file)
	}
	var out licensesFile
	index := map[string]int{}
	intern := func(text string) int {
		i, ok := index[text]
		if !ok {
			i = len(out.Texts)
			index[text] = i
			out.Texts = append(out.Texts, text)
		}
		return i
	}
	for _, g := range old.Groups {
		if g.ID == coreGroup || g.ID == platformGroup {
			continue
		}
		for i, p := range g.Packages {
			if p.Text < 0 || p.Text >= len(old.Texts) {
				return fmt.Errorf("%s: %s names text %d of %d", file, p.Name, p.Text, len(old.Texts))
			}
			g.Packages[i].Text = intern(old.Texts[p.Text])
		}
		out.Groups = append(out.Groups, g)
	}
	for _, id := range []string{coreGroup, platformGroup} {
		entries := f.groups[id]
		if len(entries) == 0 {
			continue
		}
		g := fileGroup{ID: id}
		for e, platforms := range entries {
			p := filePackage{Name: e.name, Version: e.version, License: e.license, Text: intern(e.text)}
			if len(platforms) < len(f.targets) {
				p.Platforms = slices.Sorted(slices.Values(platforms))
			}
			g.Packages = append(g.Packages, p)
		}
		slices.SortFunc(g.Packages, func(a, b filePackage) int {
			return cmpOr(strings.Compare(a.Name, b.Name), strings.Compare(a.Version, b.Version))
		})
		out.Groups = append(out.Groups, g)
	}
	data, err = json.Marshal(out)
	if err != nil {
		return err
	}
	return os.WriteFile(file, data, 0o644)
}

func cmpOr(a, b int) int {
	if a != 0 {
		return a
	}
	return b
}

// goEntries lists the Go standard library and the modules of every package linked into the platform's core.
func goEntries(platform string) ([]entry, error) {
	build, ok := goBuilds[platform]
	if !ok {
		return nil, fmt.Errorf("unknown platform %q", platform)
	}
	env := append(os.Environ(), "GOOS="+build.goos, "GOARCH=arm64", "CGO_ENABLED=1")
	cmd := exec.Command("go", append([]string{"list", "-deps", "-json"}, build.packages...)...)
	cmd.Env = env
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("go list for %s: %w", platform, err)
	}
	type module struct {
		Path, Version, Dir string
		Main               bool
		Replace            *module
	}
	var entries []entry
	seen := map[string]bool{}
	standard := false
	for decoder := json.NewDecoder(bytes.NewReader(out)); ; {
		var pkg struct {
			Standard bool
			Module   *module
		}
		if err := decoder.Decode(&pkg); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return nil, fmt.Errorf("go list for %s: %w", platform, err)
		}
		standard = standard || pkg.Standard
		m := pkg.Module
		if m == nil || m.Main || seen[m.Path] {
			continue
		}
		seen[m.Path] = true
		version, dir := m.Version, m.Dir
		if m.Replace != nil {
			version, dir = m.Replace.Version, m.Replace.Dir
		}
		text, err := licenseFiles(dir)
		if err != nil {
			return nil, fmt.Errorf("%s %s: %w", m.Path, version, err)
		}
		entries = append(entries, textEntry(m.Path, version, text))
	}
	if standard {
		cmd := exec.Command("go", "env", "GOROOT", "GOVERSION")
		cmd.Env = env
		out, err := cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("go env: %w", err)
		}
		fields := strings.Fields(string(out))
		if len(fields) < 2 {
			return nil, fmt.Errorf("go env GOROOT GOVERSION: %q", out)
		}
		// Homebrew's Go keeps the LICENSE beside GOROOT (…/Cellar/go/<version>/libexec) instead of in it.
		text, err := os.ReadFile(filepath.Join(fields[0], "LICENSE"))
		if errors.Is(err, fs.ErrNotExist) {
			text, err = os.ReadFile(filepath.Join(fields[0], "..", "LICENSE"))
		}
		if err != nil {
			return nil, err
		}
		entries = append(entries, textEntry("Go standard library", strings.TrimPrefix(fields[1], "go"), strings.TrimSpace(string(text))))
	}
	return entries, nil
}

var licenseFileName = regexp.MustCompile(`(?i)^(licen[cs]e|copying|notice)([.-].*)?$`)

// licenseFiles is every licence and notice file directly in dir, in name order.
func licenseFiles(dir string) (string, error) {
	items, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var texts []string
	for _, item := range items {
		if item.Type().IsRegular() && licenseFileName.MatchString(item.Name()) {
			data, err := os.ReadFile(filepath.Join(dir, item.Name()))
			if err != nil {
				return "", err
			}
			texts = append(texts, strings.TrimSpace(string(data)))
		}
	}
	if len(texts) == 0 {
		return "", fmt.Errorf("no licence file in %s", dir)
	}
	return strings.Join(texts, "\n\n"), nil
}

func textEntry(name, version, text string) entry {
	return entry{name: name, version: version, license: classify(text), text: text}
}

// mark compiles a phrase of a licence's wording; a space in it matches any run of white space, line breaks included.
func mark(phrase string) *regexp.Regexp {
	return regexp.MustCompile(strings.ReplaceAll(phrase, " ", `\s+`))
}

var (
	apacheMark   = mark(`Apache License,? Version 2\.0`)
	llvmMark     = mark(`LLVM Exceptions to the Apache 2\.0 License`)
	bsdMark      = mark(`Redistribution and use in source and binary forms`)
	bsdNameMark  = mark(`endorse or promote`)
	zopeMark     = mark(`Servicemarks \(sm\) or Trademarks \(tm\)`)
	gnuMark      = mark(`GNU (AFFERO |LESSER |LIBRARY )?GENERAL PUBLIC LICENSE Version (\d(\.\d)?)`)
	licenseMarks = []struct {
		id   string
		mark *regexp.Regexp
	}{
		{"Apache-2.0", apacheMark},
		{"MIT", mark(`Permission is hereby granted, free of charge, to any person obtaining`)},
		{"ISC", mark(`Permission to use, copy, modify, and(/or)? distribute this software for any purpose with or without fee is hereby granted`)},
		{"BSD", bsdMark},
		{"Zlib", mark(`provided 'as-is', without any express or implied warranty`)},
		{"MPL-2.0", mark(`Mozilla Public License,? [Vv]ersion 2\.0`)},
		{"OFL-1.1", mark(`(?i)SIL Open Font License,? Version 1\.1`)},
		{"GPL", gnuMark},
	}
)

// classify names a licence text by its SPDX id: by the licence whose own wording comes first in it, as a licence file
// that goes on to quote the licences of code it bundles (Sparkle's, Kotlin's) is its own package's. Empty when it
// knows none.
func classify(text string) string {
	id, at := "", len(text)
	for _, m := range licenseMarks {
		if loc := m.mark.FindStringIndex(text); loc != nil && loc[0] < at {
			id, at = m.id, loc[0]
		}
	}
	switch id {
	case "Apache-2.0":
		if llvmMark.MatchString(text) {
			return "Apache-2.0 WITH LLVM-exception"
		}
	case "BSD":
		// The clauses after the first: ZPL adds the service marks one, BSD-3-Clause the endorsement one.
		clauses := text[at:min(len(text), at+1500)]
		switch {
		case zopeMark.MatchString(clauses):
			return "ZPL-2.1"
		case bsdNameMark.MatchString(clauses):
			return "BSD-3-Clause"
		}
		return "BSD-2-Clause"
	case "GPL":
		m := gnuMark.FindStringSubmatch(text[at:])
		prefix := map[string]string{"AFFERO": "AGPL", "LESSER": "LGPL", "LIBRARY": "LGPL", "": "GPL"}[strings.TrimSpace(m[1])]
		version := m[2]
		if !strings.Contains(version, ".") {
			version += ".0"
		}
		return prefix + "-" + version
	}
	return id
}

// swiftEntries lists, for each platform, the Swift packages its targets link: the products project.yml names for
// the platform's targets and every package they depend on for it, by the packages' manifests. A target with a licence
// file of its own (GoogleUtilities' third_party/IsAppEncrypted) is listed beside its package.
func swiftEntries(sourcePackages, projectFile string, platforms []string) (map[string][]entry, error) {
	roots, urls, err := xcodegenProducts(projectFile)
	if err != nil {
		return nil, err
	}
	checkouts, err := swiftCheckouts(sourcePackages)
	if err != nil {
		return nil, err
	}
	manifests := map[string]*swiftManifest{}
	byPlatform := map[string][]entry{}
	for _, platform := range platforms {
		w := &swiftWalk{
			platform:   platform,
			checkouts:  checkouts,
			manifests:  manifests,
			visited:    map[string]bool{},
			used:       map[string]bool{},
			targetDirs: map[string]string{},
		}
		for _, root := range roots[platform] {
			url, ok := urls[root.pkg]
			if !ok {
				return nil, fmt.Errorf("%s: no package %s", projectFile, root.pkg)
			}
			if err := w.product(swiftIdentity(url), root.product); err != nil {
				return nil, err
			}
		}
		texts := map[string]string{}
		for _, identity := range slices.Sorted(maps.Keys(w.used)) {
			checkout := checkouts[identity]
			text, err := licenseFiles(checkout.dir)
			if err != nil {
				return nil, err
			}
			texts[identity] = text
			byPlatform[platform] = append(byPlatform[platform], textEntry(checkout.name, checkout.version, text))
		}
		for _, dir := range slices.Sorted(maps.Keys(w.targetDirs)) {
			identity := w.targetDirs[dir]
			checkout := checkouts[identity]
			for d := dir; d != checkout.dir && strings.HasPrefix(d, checkout.dir); d = filepath.Dir(d) {
				if text, err := licenseFiles(d); err == nil {
					if text != texts[identity] {
						name := filepath.ToSlash(filepath.Join(checkout.name, strings.TrimPrefix(d, checkout.dir)))
						byPlatform[platform] = append(byPlatform[platform], textEntry(name, checkout.version, text))
					}
					break
				}
			}
		}
	}
	return byPlatform, nil
}

type swiftManifest struct {
	Dependencies []struct {
		SourceControl []struct {
			Identity string `json:"identity"`
		} `json:"sourceControl"`
	} `json:"dependencies"`
	Products []swiftManifestProduct `json:"products"`
	Targets  []swiftTarget          `json:"targets"`
}

type swiftManifestProduct struct {
	Name    string   `json:"name"`
	Targets []string `json:"targets"`
}

// A target and its dependencies as `swift package dump-package` writes them: `{"byName": [name, condition]}`,
// `{"target": [name, condition]}` or `{"product": [name, package, aliases, condition]}`.
type swiftTarget struct {
	Name         string                         `json:"name"`
	Path         *string                        `json:"path"`
	Dependencies []map[string][]json.RawMessage `json:"dependencies"`
}

// swiftWalk follows products to their targets and the targets' dependencies on one platform.
type swiftWalk struct {
	platform   string
	checkouts  map[string]swiftCheckout
	manifests  map[string]*swiftManifest // by package identity, shared by the platforms' walks
	visited    map[string]bool           // "<identity>/<target>"
	used       map[string]bool           // package identities
	targetDirs map[string]string         // the visited targets' source directories, to their package's identity
}

func (w *swiftWalk) manifest(identity string) (*swiftManifest, error) {
	if m, ok := w.manifests[identity]; ok {
		return m, nil
	}
	checkout, ok := w.checkouts[identity]
	if !ok {
		return nil, fmt.Errorf("no resolved Swift package %s", identity)
	}
	cmd := exec.Command("swift", "package", "dump-package", "--package-path", checkout.dir)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("swift package dump-package --package-path %s: %w", checkout.dir, err)
	}
	m := &swiftManifest{}
	if err := json.Unmarshal(out, m); err != nil {
		return nil, fmt.Errorf("%s's manifest: %w", identity, err)
	}
	w.manifests[identity] = m
	return m, nil
}

func (w *swiftWalk) product(identity, name string) error {
	m, err := w.manifest(identity)
	if err != nil {
		return err
	}
	for _, p := range m.Products {
		if p.Name == name {
			for _, t := range p.Targets {
				if err := w.target(identity, t); err != nil {
					return err
				}
			}
			return nil
		}
	}
	return fmt.Errorf("Swift package %s has no product %s", identity, name)
}

func (w *swiftWalk) target(identity, name string) error {
	key := identity + "/" + name
	if w.visited[key] {
		return nil
	}
	w.visited[key] = true
	w.used[identity] = true
	m, err := w.manifest(identity)
	if err != nil {
		return err
	}
	i := slices.IndexFunc(m.Targets, func(t swiftTarget) bool { return t.Name == name })
	if i < 0 {
		return fmt.Errorf("Swift package %s has no target %s", identity, name)
	}
	t := m.Targets[i]
	root := w.checkouts[identity].dir
	dir := filepath.Join(root, "Sources", name)
	if t.Path != nil {
		dir = filepath.Join(root, filepath.FromSlash(*t.Path))
	}
	w.targetDirs[dir] = identity
	for _, dependency := range t.Dependencies {
		for kind, args := range dependency {
			if err := w.dependency(identity, m, kind, args); err != nil {
				return fmt.Errorf("%s/%s: %w", identity, name, err)
			}
		}
	}
	return nil
}

func (w *swiftWalk) dependency(identity string, m *swiftManifest, kind string, args []json.RawMessage) error {
	if len(args) < 2 {
		return fmt.Errorf("dependency %s %s", kind, args)
	}
	var name string
	if err := json.Unmarshal(args[0], &name); err != nil {
		return fmt.Errorf("dependency %s: %w", kind, err)
	}
	var condition *struct {
		PlatformNames []string `json:"platformNames"`
	}
	if err := json.Unmarshal(args[len(args)-1], &condition); err != nil {
		return fmt.Errorf("dependency %s's condition: %w", name, err)
	}
	if condition != nil && len(condition.PlatformNames) > 0 && !slices.Contains(condition.PlatformNames, w.platform) {
		return nil
	}
	switch kind {
	case "target":
		return w.target(identity, name)
	case "product":
		var pkg string
		if err := json.Unmarshal(args[1], &pkg); err != nil {
			return fmt.Errorf("dependency %s's package: %w", name, err)
		}
		return w.product(strings.ToLower(pkg), name)
	case "byName":
		// A target of the same package, else a product of a package it depends on.
		if slices.ContainsFunc(m.Targets, func(t swiftTarget) bool { return t.Name == name }) {
			return w.target(identity, name)
		}
		for _, d := range m.Dependencies {
			for _, source := range d.SourceControl {
				dm, err := w.manifest(source.Identity)
				if err != nil {
					return err
				}
				if slices.ContainsFunc(dm.Products, func(p swiftManifestProduct) bool { return p.Name == name }) {
					return w.product(source.Identity, name)
				}
			}
		}
		return fmt.Errorf("no target or product %s", name)
	}
	return fmt.Errorf("dependency %s of kind %s", name, kind)
}

// swiftIdentity is SwiftPM's identity of a package URL: its last path element, lowercased, without `.git`.
func swiftIdentity(url string) string {
	return strings.ToLower(strings.TrimSuffix(path.Base(strings.TrimSuffix(url, "/")), ".git"))
}

type swiftCheckout struct {
	name, version, dir string
}

// swiftCheckouts reads SourcePackages/workspace-state.json: each resolved package's version and checkout.
func swiftCheckouts(sourcePackages string) (map[string]swiftCheckout, error) {
	data, err := os.ReadFile(filepath.Join(sourcePackages, "workspace-state.json"))
	if err != nil {
		return nil, err
	}
	var state struct {
		Object struct {
			Dependencies []struct {
				PackageRef struct {
					Identity string `json:"identity"`
				} `json:"packageRef"`
				State struct {
					CheckoutState struct {
						Version  string `json:"version"`
						Revision string `json:"revision"`
					} `json:"checkoutState"`
				} `json:"state"`
				Subpath string `json:"subpath"`
			} `json:"dependencies"`
		} `json:"object"`
	}
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("workspace-state.json: %w", err)
	}
	checkouts := map[string]swiftCheckout{}
	for _, d := range state.Object.Dependencies {
		version := d.State.CheckoutState.Version
		if version == "" {
			version = d.State.CheckoutState.Revision
		}
		checkouts[d.PackageRef.Identity] = swiftCheckout{
			name:    d.Subpath,
			version: version,
			dir:     filepath.Join(sourcePackages, "checkouts", d.Subpath),
		}
	}
	return checkouts, nil
}

type swiftProduct struct{ pkg, product string }

// xcodegenProducts reads XcodeGen's project.yml: the URL of each package under `packages:`, and for each platform the
// products its targets depend on (`- package: <name>` with an optional `products: [a, b]`; without it the product
// named as the package).
func xcodegenProducts(projectFile string) (map[string][]swiftProduct, map[string]string, error) {
	file, err := os.Open(projectFile)
	if err != nil {
		return nil, nil, err
	}
	defer file.Close()
	roots := map[string][]swiftProduct{}
	urls := map[string]string{}
	var section, pkg, platform string
	var pending *swiftProduct // a `- package:` line whose products may follow
	flush := func() {
		if pending != nil {
			roots[platform] = append(roots[platform], *pending)
			pending = nil
		}
	}
	key := regexp.MustCompile(`^( *)(- )?([A-Za-z][\w-]*): *(.*)$`)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		m := key.FindStringSubmatch(strings.TrimRight(scanner.Text(), " "))
		if m == nil {
			continue
		}
		indent, item, name, value := len(m[1]), m[2] != "", m[3], m[4]
		switch {
		case indent == 0:
			flush()
			section = name
		case section == "packages" && indent == 2:
			pkg = name
		case section == "packages" && indent == 4 && name == "url":
			urls[pkg] = value
		case section == "targets" && indent == 2:
			flush()
			platform = ""
		case section == "targets" && indent == 4 && name == "platform":
			platform = strings.ToLower(value)
		case section == "targets" && item && name == "package":
			flush()
			pending = &swiftProduct{pkg: value, product: value}
		case section == "targets" && pending != nil && name == "products":
			products := strings.Split(strings.Trim(value, "[]"), ",")
			for _, product := range products {
				roots[platform] = append(roots[platform], swiftProduct{pkg: pending.pkg, product: strings.TrimSpace(product)})
			}
			pending = nil
		case item:
			flush()
		}
	}
	flush()
	return roots, urls, scanner.Err()
}

// mavenEntries lists the Maven libraries of shells/android's `licenseInputs` list, one per line:
// `<group>:<artifact>:<version>\t<POM>\t<AAR or JAR>`.
func mavenEntries(listFile, texts string) ([]entry, error) {
	data, err := os.ReadFile(listFile)
	if err != nil {
		return nil, err
	}
	var entries []entry
	embedded := map[entry]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		fields := strings.Split(line, "\t")
		coordinates := strings.Split(fields[0], ":")
		if len(fields) != 3 || len(coordinates) != 3 {
			return nil, fmt.Errorf("%s: not `<group>:<artifact>:<version>\\t<POM>\\t<file>`: %q", listFile, line)
		}
		name, version := coordinates[0]+":"+coordinates[1], coordinates[2]
		licenses, err := pomLicenses(fields[1])
		if err != nil {
			return nil, fmt.Errorf("%s: %w", fields[0], err)
		}
		files, inside, err := archiveLicenses(fields[2])
		if err != nil {
			return nil, fmt.Errorf("%s: %w", fields[2], err)
		}
		for _, e := range inside {
			embedded[e] = true
		}
		e, err := mavenEntry(name, version, licenses, files, texts)
		if err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	for e := range embedded {
		entries = append(entries, e)
	}
	return entries, nil
}

type pomLicense struct {
	Name string `xml:"name"`
	URL  string `xml:"url"`
}

var (
	apacheName = regexp.MustCompile(`(?i)apache.*2\.0|apache\.org/licenses/LICENSE-2\.0`)
	// Licences whose notice is the holder's own copyright line: a URL to the template does not give it.
	noticeName = regexp.MustCompile(`(?i)\b(BSD|MIT|ISC)\b`)
)

// mavenEntry names a library's licence by its POM and takes its text from the files in its package, else from
// -texts, else the Apache License where the POM names it; otherwise, as Google's oss-licenses plugin shows it, the
// licence's name and URL (Google's Android SDK License for the Play services libraries).
func mavenEntry(name, version string, licenses []pomLicense, files, texts string) (entry, error) {
	var ids []string
	apache := false
	for _, l := range licenses {
		switch {
		case apacheName.MatchString(l.Name + " " + l.URL):
			ids = append(ids, "Apache-2.0")
			apache = true
		case strings.Contains(l.Name, "Android Software Development Kit License"):
			ids = append(ids, "Android SDK License")
		default:
			ids = append(ids, l.Name)
		}
	}
	e := entry{name: name, version: version, license: strings.Join(ids, ", "), text: files}
	if e.text == "" && texts != "" {
		if data, err := os.ReadFile(filepath.Join(texts, strings.ReplaceAll(name, ":", "/")+".txt")); err == nil {
			e.text = string(data)
		} else if !errors.Is(err, fs.ErrNotExist) {
			return e, err
		}
	}
	if e.text != "" {
		return e, nil
	}
	if len(licenses) == 0 {
		return e, fmt.Errorf("%s %s: no licence in its POM or package", name, version)
	}
	if apache && len(licenses) == 1 {
		e.text = apacheLicense
		return e, nil
	}
	var lines []string
	for _, l := range licenses {
		if noticeName.MatchString(l.Name) {
			return e, fmt.Errorf("%s %s is %s, whose notice its package lacks: add %s.txt to -texts",
				name, version, l.Name, strings.ReplaceAll(name, ":", "/"))
		}
		lines = append(lines, l.Name, l.URL)
	}
	e.text = strings.Join(lines, "\n")
	return e, nil
}

// pomLicenses reads a POM's licences, or its parent's where it names none (Guava's listenablefuture), from the Gradle
// cache the POM is in.
func pomLicenses(pomFile string) ([]pomLicense, error) {
	data, err := os.ReadFile(pomFile)
	if err != nil {
		return nil, err
	}
	var pom struct {
		Parent struct {
			GroupID    string `xml:"groupId"`
			ArtifactID string `xml:"artifactId"`
			Version    string `xml:"version"`
		} `xml:"parent"`
		Licenses []pomLicense `xml:"licenses>license"`
	}
	if err := xml.Unmarshal(data, &pom); err != nil {
		return nil, fmt.Errorf("%s: %w", pomFile, err)
	}
	if len(pom.Licenses) > 0 || pom.Parent.ArtifactID == "" {
		return pom.Licenses, nil
	}
	// <cache>/<group>/<artifact>/<version>/<sha1>/<artifact>-<version>.pom
	cache := filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(pomFile)))))
	p := pom.Parent
	parents, _ := filepath.Glob(filepath.Join(cache, p.GroupID, p.ArtifactID, p.Version, "*", p.ArtifactID+"-"+p.Version+".pom"))
	if len(parents) == 0 {
		return nil, fmt.Errorf("%s: parent %s:%s:%s is not in %s", pomFile, p.GroupID, p.ArtifactID, p.Version, cache)
	}
	return pomLicenses(parents[0])
}

// archiveLicenses reads an AAR or JAR: its licence files, and the licences of the code compiled into it that Google's
// libraries list in third_party_licenses.json (names with offsets into third_party_licenses.txt), each as an entry.
func archiveLicenses(file string) (string, []entry, error) {
	archive, err := zip.OpenReader(file)
	if err != nil {
		return "", nil, err
	}
	defer archive.Close()
	var texts []string
	var index map[string]struct{ Start, Length int }
	var thirdParty []byte
	for _, f := range archive.File {
		base := path.Base(f.Name)
		if !licenseFileName.MatchString(base) && f.Name != "third_party_licenses.json" && f.Name != "third_party_licenses.txt" {
			continue
		}
		r, err := f.Open()
		if err != nil {
			return "", nil, err
		}
		data, err := io.ReadAll(r)
		r.Close()
		if err != nil {
			return "", nil, err
		}
		switch f.Name {
		case "third_party_licenses.json":
			if err := json.Unmarshal(data, &index); err != nil {
				return "", nil, fmt.Errorf("third_party_licenses.json: %w", err)
			}
		case "third_party_licenses.txt":
			thirdParty = data
		default:
			texts = append(texts, strings.TrimSpace(string(data)))
		}
	}
	var inside []entry
	for name, at := range index {
		if at.Start < 0 || at.Start+at.Length > len(thirdParty) {
			return "", nil, fmt.Errorf("third_party_licenses.json: %s is outside third_party_licenses.txt", name)
		}
		inside = append(inside, textEntry(name, "", strings.TrimSpace(string(thirdParty[at.Start:at.Start+at.Length]))))
	}
	return strings.Join(texts, "\n\n"), inside, nil
}

// nugetEntry reads an unpacked NuGet package's .nuspec: its id, version and licence file.
func nugetEntry(dir string) (entry, error) {
	specs, _ := filepath.Glob(filepath.Join(dir, "*.nuspec"))
	if len(specs) != 1 {
		return entry{}, fmt.Errorf("%s: expected one .nuspec, found %d", dir, len(specs))
	}
	data, err := os.ReadFile(specs[0])
	if err != nil {
		return entry{}, err
	}
	var spec struct {
		ID      string `xml:"metadata>id"`
		Version string `xml:"metadata>version"`
		License struct {
			Type  string `xml:"type,attr"`
			Value string `xml:",chardata"`
		} `xml:"metadata>license"`
	}
	if err := xml.Unmarshal(bytes.TrimPrefix(data, []byte("\uFEFF")), &spec); err != nil {
		return entry{}, fmt.Errorf("%s: %w", specs[0], err)
	}
	if spec.License.Type != "file" {
		return entry{}, fmt.Errorf("%s: licence %q is not a file", specs[0], spec.License.Value)
	}
	text, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(spec.License.Value)))
	if err != nil {
		return entry{}, err
	}
	return textEntry(spec.ID, spec.Version, strings.TrimSpace(string(text))), nil
}

// noticeEntry reads `<name>[@<version>]=<file>`.
func noticeEntry(notice string) (entry, error) {
	label, file, ok := strings.Cut(notice, "=")
	if !ok {
		return entry{}, fmt.Errorf("-notice %q: expected <name>[@<version>]=<file>", notice)
	}
	name, version, _ := strings.Cut(label, "@")
	text, err := os.ReadFile(file)
	if err != nil {
		return entry{}, err
	}
	return textEntry(name, version, strings.TrimSpace(string(text))), nil
}
