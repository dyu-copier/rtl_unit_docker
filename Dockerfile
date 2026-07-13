FROM ghcr.io/librelane/librelane:3.0.4

# Base image already contains:
#   OpenROAD, OpenSTA, Yosys (+sby, +eqy), Magic, KLayout, Netgen,
#   Verilator, ngspice, Surelog, z3, Python 3, git

# ── Additional tools via Nix ─────────────────────────────────────────────────
# bluespec               : Bluespec Compiler (nixpkgs.bluespec, not nixpkgs.bsc which is libbsc)
# verilog                : Icarus Verilog
# pandoc                 : documentation generation
# wget / curl            : needed by later RUN steps
# gcc                    : bsc's `-sim` backend generates a C++ wrapper for
#                          Bluesim and links it with `c++`/`g++` at build
#                          time -- neither the base image nor any other
#                          package here provides one, so every `bsc -sim
#                          ... -e ...` link step fails with "c++: command
#                          not found" without this.
# python3Packages.pip    : Nix Python envs strip pip; install explicitly so
#                          we can create a venv in a writable location
RUN nix-channel --add https://nixos.org/channels/nixos-23.11 nixpkgs \
 && nix-channel --update \
 && nix-env -iA \
      nixpkgs.bluespec \
      nixpkgs.gnumake \
      nixpkgs.pandoc \
      nixpkgs.wget \
      nixpkgs.curl \
      nixpkgs.gcc \
      nixpkgs.python3Packages.pip \
      nixpkgs.python3Packages.setuptools \
      nixpkgs.python3Packages.wheel

# /usr/local/bin: verible static binaries installed there
ENV PATH=/root/.nix-profile/bin:/usr/local/bin:$PATH

# ── Python toolchain in a writable venv ──────────────────────────────────────
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir \
      copier \
      click \
      cocotb \
      cocotb-coverage \
      cocotbext-apb \
      cocotbext-axi \
      "peakrdl>=1.0.0" \
      "peakrdl-bsv>=0.0.1" \
      "peakrdl-html>=2.11.0" \
      "peakrdl-markdown>=1.0.2" \
      "peakrdl-python>=1.4.0" \
      "peakrdl-regblock>=0.14.0" \
      "peakrdl-cocotb-ralgen"

ENV PATH=/opt/venv/bin:$PATH

# ── Verible: SystemVerilog linter + formatter (static Linux binary) ──────────
ARG VERIBLE_TAG=v0.0-4080-ga0a8d8eb
RUN wget -q \
      "https://github.com/chipsalliance/verible/releases/download/${VERIBLE_TAG}/verible-${VERIBLE_TAG}-linux-static-x86_64.tar.gz" \
      -O /tmp/verible.tar.gz \
 && mkdir -p /usr/local/bin \
 && tar xf /tmp/verible.tar.gz -C /tmp \
 && cp /tmp/verible-${VERIBLE_TAG}/bin/* /usr/local/bin/ \
 && rm -rf /tmp/verible-${VERIBLE_TAG} /tmp/verible.tar.gz

# ── BSC environment ──────────────────────────────────────────────────────────
# The nixos-23.11 bsc-3.1.0 package includes bin/include/lib but omits the
# Verilog simulation models (lib/Verilog/*.v).  We create a writable
# /opt/bsc that mirrors the nix package and adds the missing Verilog files
# fetched from the BSC GitHub repo via a sparse clone.
RUN bash << 'EOF'
set -euo pipefail

bsc_nix=$(dirname "$(dirname "$(realpath "$(which bsc)")")")
echo "BSC nix pkg: $bsc_nix"
echo "  top-level:  $(ls "$bsc_nix")"
echo "  lib/:       $(ls "$bsc_nix/lib/" 2>/dev/null || echo '(empty)')"

# Build a writable BLUESPEC_HOME that mirrors the nix package content
mkdir -p /opt/bsc/lib
# Symlink every subdir of lib/ (Libraries, tcllib, etc.) from the nix store
for d in "$bsc_nix/lib"/*/; do
    [ -d "$d" ] || continue
    ln -sf "$(realpath "$d")" "/opt/bsc/lib/$(basename "$d")"
done
# Symlink bin/ and include/ from the nix store
for item in bin include; do
    [ -e "$bsc_nix/$item" ] && ln -sf "$bsc_nix/$item" "/opt/bsc/$item" || true
done

# Check if Verilog simulation models already came in via the lib/ symlinks
if ls /opt/bsc/lib/Verilog/*.v >/dev/null 2>&1; then
    echo "BSC Verilog models present ($(ls /opt/bsc/lib/Verilog/*.v | wc -l) files)"
    exit 0
fi

# Not in the nix package — sparse-clone just src/Verilog from BSC GitHub
echo "BSC Verilog models absent from nix pkg; fetching from GitHub..."
git clone --depth=1 --filter=blob:none --sparse \
    https://github.com/B-Lang-org/bsc.git /tmp/bsc-src
git -C /tmp/bsc-src sparse-checkout set src/Verilog
git -C /tmp/bsc-src checkout

mkdir -p /opt/bsc/lib/Verilog
cp /tmp/bsc-src/src/Verilog/*.v /opt/bsc/lib/Verilog/
rm -rf /tmp/bsc-src
echo "Installed $(ls /opt/bsc/lib/Verilog/*.v | wc -l) BSC Verilog simulation models"
EOF
ENV BLUESPEC_HOME=/opt/bsc
ENV BSC_PATH=+

# ── sky130A PDK ──────────────────────────────────────────────────────────────
ARG SKY130_HASH=8afc8346a57fe1ab7934ba5a6056ea8b43078e71
ENV PDK_ROOT=/opt/pdk
RUN ciel enable --pdk sky130 --pdk-root ${PDK_ROOT} ${SKY130_HASH}

# ── FHS compatibility ─────────────────────────────────────────────────────────
# Generated Makefiles use SHELL=/bin/bash; LibreLane's Nix base has no /bin/bash.
# gnused provides 'sed' in /root/.nix-profile/bin (Nix container has no system sed).
RUN bash -c 'mkdir -p /bin && ln -sf "$(which bash)" /bin/bash'
RUN nix-env -iA nixpkgs.gnused

# GitHub Actions injects its own prebuilt (glibc-linked) Node.js binary into
# container-based jobs at /__e/nodeXX/bin/node for internal steps (e.g. the
# checkout action and the post-job "determine container OS" cleanup step)
# -- this fails on a Nix root two ways, confirmed against real CI runs:
#   1. "no such file or directory" executing node itself, since Nix's
#      glibc lives under /nix/store/... and this image never populates
#      the conventional /lib64/ld-linux-x86-64.so.2 dynamic-linker path
#      that path-injected glibc binaries hard-code as their interpreter.
#   2. once (1) is fixed, node still fails to load libstdc++.so.6, since
#      it isn't on this image's default library search path either.
#
# For (2): do NOT use a global LD_LIBRARY_PATH (tried this first -- broke
# `yosys`, which silently started resolving an OLDER libstdc++ instead of
# the newer one it actually needs, since LD_LIBRARY_PATH takes priority
# over a binary's own RPATH/RUNPATH). Also do NOT rely on `ldd`+`awk` to
# discover it, or `ldconfig` to register it (this minimal Nix root has
# neither `awk` nor `ldconfig` -- confirmed via a failed build, exit 127
# each time). Instead, symlink libstdc++.so.6 from the nixpkgs.gcc
# package (installed above) directly into /lib64 -- one of the dynamic
# linker's own hard-coded default search directories, consulted only
# AFTER any binary's own RPATH/RUNPATH, so tools that already resolve
# their own libstdc++ correctly (yosys) are unaffected; only Node (which
# has no such mechanism here) falls through to it. Uses only find/ln/
# realpath, the same tools the ld-linux-x86-64.so.2 fix below already
# uses successfully.
RUN bash << 'EOF'
set -euo pipefail
nix-env -iA nixpkgs.glibc
mkdir -p /lib64
ld_so=$(find /root/.nix-profile /nix/store -maxdepth 4 -name 'ld-linux-x86-64.so.2' 2>/dev/null | head -1)
if [ -z "$ld_so" ]; then
    echo "ERROR: could not locate ld-linux-x86-64.so.2 under the Nix store" >&2
    exit 1
fi
ln -sf "$(realpath "$ld_so")" /lib64/ld-linux-x86-64.so.2
echo "Linked dynamic linker: /lib64/ld-linux-x86-64.so.2 -> $(realpath "$ld_so")"

libstdcxx_path=$(find /root/.nix-profile /nix/store -maxdepth 4 -name 'libstdc++.so.6' 2>/dev/null | head -1)
if [ -z "$libstdcxx_path" ]; then
    echo "ERROR: could not locate libstdc++.so.6 under the Nix store" >&2
    exit 1
fi
ln -sf "$(realpath "$libstdcxx_path")" /lib64/libstdc++.so.6
echo "Linked fallback libstdc++.so.6: /lib64/libstdc++.so.6 -> $(realpath "$libstdcxx_path")"
EOF

WORKDIR /work
CMD ["/bin/bash"]
