# Builds the Linux shell (build.sh) and runs its headless smoke test (smoke.sh): Ubuntu 24.04, the oldest system the
# plain build supports, with Go, GTK 4, WebKitGTK 6, libsecret, CMake, and Xvfb, a D-Bus session bus, gnome-keyring
# (the secret service the smoke run's secret check talks to) and xwd/netpbm for the screenshot.
FROM ubuntu:24.04
ARG TARGETARCH
ARG GO_VERSION=1.26.2
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl g++ cmake ninja-build pkg-config \
        libgtk-4-dev libwebkitgtk-6.0-dev libsecret-1-dev \
        xvfb xauth dbus gnome-keyring x11-apps netpbm fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=local
