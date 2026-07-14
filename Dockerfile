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
# yices / z3             : SMT solvers for SymbiYosys (sby's smtbmc engine
#                          defaults to yices; the base image's z3 is not on
#                          PATH at runtime, so formal falls back to abc and
#                          then fails reconstructing traces via yices)
RUN nix-channel --add https://nixos.org/channels/nixos-23.11 nixpkgs \
 && nix-channel --update \
 && nix-env -iA \
      nixpkgs.bluespec \
      nixpkgs.gnumake \
      nixpkgs.pandoc \
      nixpkgs.wget \
      nixpkgs.curl \
      nixpkgs.gcc \
      nixpkgs.yices \
      nixpkgs.z3 \
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

WORKDIR /work
CMD ["/bin/bash"]
