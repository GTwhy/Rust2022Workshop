#!/bin/bash

# It is recommended to use root for trial

# install dependences
sudo apt update

sudo apt install -y libibverbs1 ibverbs-utils librdmacm1 libibumad3 ibverbs-providers rdma-core libibverbs-dev iproute2 perftest build-essential net-tools git librdmacm-dev rdmacm-utils cmake libprotobuf-dev protobuf-compiler clang curl pkg-config

# install rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --default-toolchain 1.61.0 -y &&
source "$HOME/.cargo/env"

# link rdma netdev
if [ `ifconfig -s | grep -c '^e'` -eq 0 ]; then
    echo "no eth device"
    exit 1
elif [ `ifconfig -s | grep -c '^e'` -gt 1 ]; then
    echo "multiple eth devices, select the first one"
    ifconfig -s | grep '^e'
fi

ETH_DEV=`ifconfig -s | grep '^e' | cut -d ' ' -f 1 | head -n 1`
RXE_DEV=rxe_eth0

sudo rdma link delete $RXE_DEV
sudo rdma link add $RXE_DEV type rxe netdev $ETH_DEV
rdma link | grep $RXE_DEV

# clone && build && test async-rdma
# use domestic mirror here
# replace "kgithub" with "github" if you can access it
# git clone https://github.com/datenlord/async-rdma.git &&
git config --global http.sslVerify false
git clone https://kgithub.com/datenlord/async-rdma.git &&

cd async-rdma &&
cargo b &&
cargo t