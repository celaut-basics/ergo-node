# linux/amd64 pack root. nodo builds it with --opt platform=linux/amd64 (from
# service.json). The base image pin is a multi-arch index, so the same pin
# resolves to the linux/amd64 image. Only the Temurin JRE tarball (x64) and its
# checksum differ from the other pack root. The Debian pins below exist at the
# same versions on amd64 and arm64.
#
# Every dependency is pinned, and the three that matter are pinned by digest or by
# checksum. This service is content-addressed -- two packs of the same source tree must
# produce the same image -- and when ERGO_WALLET_MNEMONIC is set the image holds a
# wallet, so "whatever was on that tag today" is not a thing to build a key holder out
# of.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

# ---------------------------------------------------------------------------- JVM
# Eclipse Temurin's JRE tarball, pinned by the SHA-256 Adoptium publishes for it,
# rather than Debian's `openjdk-17-jre-headless`.
#
# Debian's package is one `apt-get install` and would have been the shorter line. It
# is not the one taken, for a reason this file already lives by everywhere else: it
# pulls thirty-two other packages -- fontconfig, libcups2, libnss3, libavahi-client3,
# a DejaVu font -- and pinning *one* of them to a version pins none of the rest. A
# headless node that validates blocks has no use for a CUPS client or a font, and each
# of those is a package this image would be carrying unpinned and unread.
#
# The tarball is one artifact, one checksum, one line of diff when it moves. That is
# exactly the trade this service makes for the Ergo release below, made once more, and
# it is the same discipline `celaut-basics/bitcoin-node` applies to the Core tarball.
#
# `17.0.20.1+1` because Ergo 6.0.5 targets a Java 11+ runtime and the project's own
# release notes and Docker images run it on 17; 21 works too and is a bigger change
# than this file should make on its own.
#
#   curl -s 'https://api.adoptium.net/v3/assets/feature_releases/17/ga?architecture=x64&image_type=jre&jvm_impl=hotspot&os=linux&page_size=1&vendor=eclipse' \
#     | jq -r '.[0].binaries[0].package | .link, .checksum'
#
# The guest does not get the ENV of this file. nodo exports only the filesystem, and
# its /init sets PATH to the standard directories. Thus the entrypoint calls
# /opt/java/bin/java by its full path, and the link in /usr/local/bin is only for an
# operator in a shell.
ARG TEMURIN_VERSION=17.0.20.1_1
ARG TEMURIN_SHA256=0b2b640e3046b64c8ec504de0ab9d91bb5610182bda21fad454681ce54d45a62
ADD https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jre_x64_linux_hotspot_${TEMURIN_VERSION}.tar.gz /tmp/jre.tar.gz
RUN echo "${TEMURIN_SHA256}  /tmp/jre.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/java \
    && tar -xzf /tmp/jre.tar.gz -C /opt/java --strip-components=1 \
    && rm -f /tmp/jre.tar.gz \
    && ln -s /opt/java/bin/java /usr/local/bin/java \
    && /opt/java/bin/java -version

# ------------------------------------------------------------------------ the node
# The Ergo reference client, from the release the project publishes.
#
# 6.0.5 and not 6.1.5: 6.1.x is marked `prerelease` on the releases API, and the latest
# one that is not is what a node holding a wallet should be running. The jar is the same
# on every architecture -- it is JVM bytecode -- which is why `architecture` in
# service.json describes only the base image and the JRE above.
#
# The checksum is one this file's author computed from the published artifact:
#
#   curl -sL -o ergo-6.0.5.jar https://github.com/ergoplatform/ergo/releases/download/v6.0.5/ergo-6.0.5.jar
#   shasum -a 256 ergo-6.0.5.jar
#
# Ergo publishes no SHA256SUMS file of its own, so unlike Bitcoin Core's there is no
# upstream document to compare this against: what is pinned here is *an* artifact, in a
# reviewed file, which cannot change without a diff. That is weaker than a signed sums
# file and is stated rather than glossed over. Verifying the release signature would be
# the improvement, and it needs the project's keys in the image.
ARG ERGO_VERSION=6.0.5
ARG ERGO_SHA256=2a7e2978cb09538ed6780d85ae3aa39c1ecce10e5e5a6e0dc3cd8ab087851588
ADD https://github.com/ergoplatform/ergo/releases/download/v${ERGO_VERSION}/ergo-${ERGO_VERSION}.jar /opt/ergo/ergo.jar
RUN echo "${ERGO_SHA256}  /opt/ergo/ergo.jar" | sha256sum -c -

# ------------------------------------------------------------------------ packages
# Three packages and their libraries, pinned to the version and not to the suite,
# because an image that may hold a wallet should be the same image tomorrow.
#
#  protobuf-compiler  `protoc --decode=celaut.ConfigurationFile`. The `__config__` a
#                     node writes for this instance is a *binary* protobuf, and the
#                     peers this service is supposed to dial are inside it. Decoding it
#                     is the one thing the entrypoint cannot do with what the base image
#                     ships, so the decoder is in the image and `celaut.proto` is
#                     vendored next to the script that uses it.
#  curl               the node's own REST API, on loopback: /info to wait for it, and
#                     /wallet/restore to hand it a mnemonic.
#  jq                 those answers, read without a JSON parser written in shell.
#
# Not here, deliberately:
#
#  openssl  BLAKE2b-256 is what `scorex.restApi.apiKeyHash` holds, and OpenSSL 3.0
#           exposes BLAKE2b at 512-bit output only (`openssl dgst -blake2b512`) with no
#           way to ask for a 256-bit digest -- which is a *different* hash, not a
#           truncation. `b2sum -l 256`, from the coreutils already in the base image,
#           is the right primitive, and it agrees with the node's own
#           `/utils/hash/blake2b` on the test vector this service's tests pin.
#  python   the entrypoint is `bash`, `protoc`, `awk`, `curl` and `jq`. A language
#           runtime in an image that holds a mnemonic is a large thing to audit for a
#           job four tools already do -- the same call `celaut-basics/bitcoin-node`
#           made when it dropped Python from its own image.
#
# Pinning to the patch version means a Debian security update does not silently change
# this image -- and equally that the build stops until this file is edited when the old
# version leaves the mirror. That is the same trade already made for the JRE and the
# jar, made once more.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        protobuf-compiler=3.21.12-3+deb12u1 \
        libprotobuf32=3.21.12-3+deb12u1 \
        libprotoc32=3.21.12-3+deb12u1 \
        curl=7.88.1-10+deb12u15 \
        libcurl4=7.88.1-10+deb12u15 \
        jq=1.6-2.1+deb12u2 \
        libjq1=1.6-2.1+deb12u2 \
        libonig5=6.9.8-1 \
    && rm -rf /var/lib/apt/lists/*

# `celaut.proto` and `buffer.proto` are vendored from celaut-project/nodo rather than
# fetched: the schema this decodes has to be the one the node that wrote the file was
# built from, and a copy in the tree is a copy that shows up in a diff when it drifts.
# `buffer.proto` is here only because `celaut.proto` imports it; nothing in this service
# reads a Buffer.
#
# The build context is `.service/`, and the packer puts the `include` items of
# pack_config.json in `.service/service/`. Thus the source directory is
# `service/service` in the context. The packer changes an origin that starts with `./`
# to `service/...`, so `./service` is that directory. A bare `service` is not changed
# and copies the wrapper directory, which puts the script at /service/service/.
COPY ./service /service
RUN chmod +x /service/entrypoint.sh && mkdir -p /data
