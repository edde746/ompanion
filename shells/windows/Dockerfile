# The cross toolchain for build.sh: llvm-mingw for the shell and cgo, plus Go for the core's c-shared build.
FROM mstorsjo/llvm-mingw:20261020
COPY --from=golang:1.26.9-trixie /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH
