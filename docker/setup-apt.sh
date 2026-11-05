#!/bin/sh
# Replace the image's apt sources with the pinned ones of the distribution:
#
#   setup-apt.sh <sources.list>
#
# Pinned sources are frozen (archive.debian.org or a snapshot.debian.org
# timestamp), so their Release files are past Valid-Until on purpose.
set -eu

cp "$1" /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources

cat > /etc/apt/apt.conf.d/99gcc-backports <<EOF
Acquire::Check-Valid-Until "false";
Acquire::Retries "10";
Acquire::http::Timeout "120";
// snapshot.debian.org throttles parallel and pipelined requests; fetch
// one file at a time over a single connection.
Acquire::Queue-Mode "access";
Acquire::http::Pipeline-Depth "0";
APT::Install-Recommends "false";
EOF
