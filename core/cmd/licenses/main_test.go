package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestClassify(t *testing.T) {
	bsd := "Redistribution and use in source and binary forms, with or without\nmodification, are permitted"
	cases := map[string]string{
		"Copyright (c) 2011 Keith Rarick\n\nPermission is hereby granted, free of charge, to any person\nobtaining a copy":        "MIT",
		bsd + " provided that the following conditions are met:":                                                                  "BSD-2-Clause",
		bsd + "\n * Neither the name of Google LLC nor the names of its contributors may be used to endorse or\npromote":          "BSD-3-Clause",
		bsd + "\n 4. The right to distribute this software … Servicemarks (sm) or Trademarks (tm) of the holders":                 "ZPL-2.1",
		"This software is provided 'as-is', without any express or \nimplied warranty.":                                           "Zlib",
		"Permission to use, copy, modify, and/or distribute this software for any\npurpose with or without fee is hereby granted": "ISC",
		"Licensed under the Apache License, Version 2.0 (the \"License\")":                                                        "Apache-2.0",
		"Apache License\n Version 2.0, January 2004 … ---- LLVM Exceptions to the Apache 2.0 License ----":                        "Apache-2.0 WITH LLVM-exception",
		"MIT License\n\nPermission is hereby granted, free of charge, to any person obtaining … EXTERNAL LICENSES … " +
			"GNU GENERAL PUBLIC LICENSE\nVersion 2": "MIT",
		"GNU LESSER GENERAL PUBLIC LICENSE\n Version 2.1, February 1999": "LGPL-2.1",
		"GNU AFFERO GENERAL PUBLIC LICENSE\n Version 3":                  "AGPL-3.0",
		"Mozilla Public License Version 2.0":                             "MPL-2.0",
		"Copyright 2012 Example. All rights reserved.":                   "",
	}
	for text, want := range cases {
		if got := classify(text); got != want {
			t.Errorf("classify(%q) = %q, want %q", text, got, want)
		}
	}
}

func TestXcodegenProducts(t *testing.T) {
	project := filepath.Join(t.TempDir(), "project.yml")
	yml := `name: app
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: 2.10.0
  Firebase:
    url: https://github.com/firebase/firebase-ios-sdk.git
targets:
  app-macOS:
    type: application
    platform: macOS
    dependencies:
      - framework: Core.xcframework
        embed: false
      - package: Sparkle
  app-iOS:
    platform: iOS
    dependencies:
      - package: Firebase
        products: [FirebaseCore, FirebaseMessaging]
      - target: Extension
  Extension:
    platform: iOS
`
	if err := os.WriteFile(project, []byte(yml), 0o644); err != nil {
		t.Fatal(err)
	}
	roots, urls, err := xcodegenProducts(project)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]swiftProduct{
		"macos": {{"Sparkle", "Sparkle"}},
		"ios":   {{"Firebase", "FirebaseCore"}, {"Firebase", "FirebaseMessaging"}},
	}
	for platform, products := range want {
		if !slices.Equal(roots[platform], products) {
			t.Errorf("%s: %v, want %v", platform, roots[platform], products)
		}
	}
	if got := swiftIdentity(urls["Firebase"]); got != "firebase-ios-sdk" {
		t.Errorf("identity %q", got)
	}
}

func TestMavenEntry(t *testing.T) {
	texts := t.TempDir()
	apache := []pomLicense{{Name: "The Apache Software License, Version 2.0", URL: "http://www.apache.org/licenses/LICENSE-2.0.txt"}}
	sdk := []pomLicense{{Name: "Android Software Development Kit License", URL: "https://developer.android.com/studio/terms.html"}}
	bsd := []pomLicense{{Name: "BSD-3-Clause", URL: "https://opensource.org/licenses/BSD-3-Clause"}}

	e, err := mavenEntry("androidx.core:core", "1.18.0", apache, "its own LICENSE.txt", texts)
	if err != nil || e.text != "its own LICENSE.txt" || e.license != "Apache-2.0" {
		t.Errorf("own file: %+v %v", e, err)
	}
	e, err = mavenEntry("javax.inject:javax.inject", "1", apache, "", texts)
	if err != nil || e.text != apacheLicense {
		t.Errorf("Apache without a file: %+v %v", e.license, err)
	}
	e, err = mavenEntry("com.google.android.gms:play-services-base", "18.9.0", sdk, "", texts)
	if err != nil || e.license != "Android SDK License" || !strings.Contains(e.text, "developer.android.com/studio/terms") {
		t.Errorf("SDK licence: %+v %v", e, err)
	}
	if _, err := mavenEntry("a.b:c", "1", bsd, "", texts); err == nil {
		t.Error("BSD without its notice: no error")
	}
	if err := os.MkdirAll(filepath.Join(texts, "a.b"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(texts, "a.b", "c.txt"), []byte("Copyright 2008 Google Inc."), 0o644); err != nil {
		t.Fatal(err)
	}
	if e, err := mavenEntry("a.b:c", "1", bsd, "", texts); err != nil || e.text != "Copyright 2008 Google Inc." {
		t.Errorf("BSD with -texts: %+v %v", e, err)
	}
	if _, err := mavenEntry("a.b:d", "1", nil, "", texts); err == nil {
		t.Error("no licence: no error")
	}
}
