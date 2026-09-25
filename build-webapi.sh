#!/usr/bin/env bash
#
# build-webapi.sh — install a JDK and build WebAPI 3.0 (webapi-3.0-trino branch).
#
# WebAPI 3.0 REQUIRES Java 21 (the pom is pinned to maven.compiler.release=21).
# Java 17 (the 2.x requirement) will NOT build this branch.
#
# Usage:
#   ./build-webapi.sh
#
# Tunable environment variables:
#   JAVA_VERSION=21            JDK major version to use/install (21 is required)
#   PROFILE=webapi-trino       Maven profile ('' or 'none' builds without Trino support)
#   SKIP_TESTS=1               Skip unit tests (set to 0 to run them)
#   JDK_INSTALL_DIR=$HOME/.jdks
#                              Where the Temurin JDK is extracted when the system
#                              package manager cannot be used (no root/sudo)
#   OHDSI_TRINO_REPO_DIR=/data/ohdsi_jars
#                              Optional local file repository for custom Trino
#                              OHDSI jars (passed to Maven as -Dohdsi.trino.repo.dir).
#                              Only needed if you installed a custom SqlRender with
#                              a Trino dialect (see /data/ohdsi_jars/README.md).
#   EXTRA_MAVEN_ARGS="..."     Extra Maven arguments, e.g. to use a custom SqlRender
#                              build: EXTRA_MAVEN_ARGS="-DSqlRender.version=1.19.1-trino.1"
#   JAVA_HOME=<path>           If set and it contains a matching javac, it is used
#                              as-is and no JDK installation is attempted
#
# Example on a fresh server where /data is not available:
#   OHDSI_TRINO_REPO_DIR=$HOME/ohdsi_jars ./build-webapi.sh

set -euo pipefail

JAVA_VERSION="${JAVA_VERSION:-21}"
PROFILE="${PROFILE:-webapi-trino}"
SKIP_TESTS="${SKIP_TESTS:-1}"
JDK_INSTALL_DIR="${JDK_INSTALL_DIR:-$HOME/.jdks}"
OHDSI_TRINO_REPO_DIR="${OHDSI_TRINO_REPO_DIR:-/data/ohdsi_jars}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Print the major version of the javac inside a JDK home ('' if not a JDK home).
jdk_major() {
  [ -x "$1/bin/javac" ] || return 0
  "$1/bin/javac" -version 2>&1 | awk '{print $2}' | cut -d. -f1
}

# --- 1. Find or install a JDK ------------------------------------------------
choose_jdk() {
  local base v
  # Honor an explicit JAVA_HOME first.
  if [ -n "${JAVA_HOME:-}" ] && [ "$(jdk_major "$JAVA_HOME")" = "$JAVA_VERSION" ]; then
    echo "$JAVA_HOME"; return 0
  fi
  for base in /usr/lib/jvm /opt "$JDK_INSTALL_DIR" /data; do
    [ -d "$base" ] || continue
    for v in "$base"/*; do
      [ -d "$v" ] || continue
      if [ "$(jdk_major "$v")" = "$JAVA_VERSION" ]; then
        echo "$v"; return 0
      fi
    done
  done
  return 0
}

install_package_jdk() {
  # Only works with passwordless sudo; otherwise returns 1 for the tarball path.
  sudo -n true 2>/dev/null || return 1
  log "Installing OpenJDK $JAVA_VERSION via the system package manager"
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "java-$JAVA_VERSION-openjdk-devel"
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y "java-$JAVA_VERSION-openjdk-devel"
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y "openjdk-$JAVA_VERSION-jdk"
  else
    return 1
  fi
  local v
  for v in /usr/lib/jvm/*; do
    if [ "$(jdk_major "$v")" = "$JAVA_VERSION" ]; then
      echo "$v"; return 0
    fi
  done
  return 1
}

install_temurin_jdk() {
  mkdir -p "$JDK_INSTALL_DIR"
  local url="https://api.adoptium.net/v3/binary/latest/$JAVA_VERSION/ga/linux/x64/jdk/hotspot/normal/eclipse"
  local tarball="$JDK_INSTALL_DIR/.temurin-$JAVA_VERSION.tar.gz"
  local xdir="$JDK_INSTALL_DIR/.extract-$JAVA_VERSION"
  log "No suitable JDK found - downloading Temurin JDK $JAVA_VERSION to $JDK_INSTALL_DIR (no root needed)"
  command -v curl >/dev/null 2>&1 || die "curl is required to download the JDK"
  curl -fsSL --retry 3 -o "$tarball" "$url"
  mkdir -p "$xdir"
  tar xzf "$tarball" -C "$xdir"
  rm -f "$tarball"
  local javac
  javac="$(find "$xdir" -maxdepth 3 -path '*/bin/javac' -type f | head -1)"
  [ -n "$javac" ] || die "Temurin download did not yield a usable JDK"
  local home
  home="$(dirname "$(dirname "$javac")")"
  mv "$home" "$JDK_INSTALL_DIR/jdk-$JAVA_VERSION"
  rm -rf "$xdir"
  echo "$JDK_INSTALL_DIR/jdk-$JAVA_VERSION"
}

JDK_HOME="$(choose_jdk || true)"
if [ -z "$JDK_HOME" ]; then
  JDK_HOME="$(install_package_jdk || true)"
fi
if [ -z "$JDK_HOME" ]; then
  JDK_HOME="$(install_temurin_jdk)"
fi
export JAVA_HOME="$JDK_HOME"
export PATH="$JAVA_HOME/bin:$PATH"
log "Using JDK: $JAVA_HOME  ($("$JAVA_HOME/bin/java" -version 2>&1 | head -1))"
if [ "$JAVA_VERSION" != "21" ]; then
  warn "WebAPI 3.0 compiles with maven.compiler.release=21; a Java $JAVA_VERSION build will most likely fail."
fi

# --- 2. Check the local Trino jar repository (optional) ------------------------
if [ "$PROFILE" = "webapi-trino" ] && [ ! -d "$OHDSI_TRINO_REPO_DIR" ]; then
  warn "Local Trino jar repository not found: $OHDSI_TRINO_REPO_DIR"
  warn "This only matters if you installed a custom SqlRender with a Trino dialect"
  warn "(then set OHDSI_TRINO_REPO_DIR to its location); otherwise the build"
  warn "resolves everything from repo.ohdsi.org and Maven Central."
fi

# --- 3. Build -----------------------------------------------------------------
cd "$SCRIPT_DIR"
MVN_ARGS=(-B clean package)
if [ "$SKIP_TESTS" = "1" ]; then
  # The pom binds surefire/failsafe to its own properties (skipUnitTests /
  # skipITtests), which override a plain -DskipTests, so pass all of them.
  MVN_ARGS+=(-DskipTests=true -DskipUnitTests=true -DskipITtests=true)
fi
case "$PROFILE" in
  ""|none) ;;
  *) MVN_ARGS+=(-P"$PROFILE" -Dohdsi.trino.repo.dir="$OHDSI_TRINO_REPO_DIR") ;;
esac
# Extra Maven arguments, e.g. EXTRA_MAVEN_ARGS="-DSqlRender.version=1.19.1-trino.1"
# (word-splitting is intentional: the value is a list of -D flags)
if [ -n "${EXTRA_MAVEN_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  MVN_ARGS+=(${EXTRA_MAVEN_ARGS})
fi
log "Building: ./mvnw ${MVN_ARGS[*]}"
./mvnw "${MVN_ARGS[@]}"

log "Build finished. Artifacts:"
ls -lh "$SCRIPT_DIR"/target/*.war "$SCRIPT_DIR"/target/*.jar 2>/dev/null || ls -lh "$SCRIPT_DIR"/target
