# KVCache

## Introduction

KVCache is a high-performance, low-latency key-value store built using [Seastar](https://seastar.io) and [DPDK](https://dpdk.org). It aims to provide a Redis compatible interface, as a viable drop-in replacement.

## Prerequisites

KVCache requires the following dependencies:
- CMake (version 3.16 or higher)
- A modern C++20 compiler (GCC 10+ or Clang 11+)
- Seastar framework
- Optional: DPDK for network acceleration

## Build Instructions

### Installing DPDK (Optional)

To enable hardware-accelerated networking, install DPDK:

```bash
# Download and extract DPDK
wget https://fast.dpdk.org/rel/dpdk-23.07.tar.xz
tar xf dpdk-23.07.tar.xz
cd dpdk-23.07

# Configure and install
meson setup -Dmbuf_refcnt_atomic=false build
ninja -C build install
```

### Installing Seastar

Install the Seastar framework with core optimizations:

```bash
# Clone Seastar repository
git clone https://github.com/scylladb/seastar.git --depth 1
cd seastar

# Install system dependencies
sudo ./install-dependencies.sh

# Configure and build
./configure.py \
    --mode=release \
    --enable-io_uring \
    --cook fmt \
    --c++-standard=20 # --enable-dpdk
```

### Compiling KVCache

```bash
# Prepare build directory
mkdir build && cd build

# Configure and build
cmake -G Ninja ..
ninja
```

## License

Distributed under the Apache License, Version 2.0. See `LICENSE` file for complete details.


**Disclaimer: KVCache is under active development. Use in production is HIGHLY discouraged.**