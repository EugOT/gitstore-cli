# syntax=docker/dockerfile:1.7

FROM fedora:43@sha256:762d73ba1c455232b0272c5d445a34f36c4b9f421cbc05ce8102552325b6a222

ARG TARGETARCH
ARG BUN_VERSION=1.3.0
ARG BUN_SHA256_AMD64=60c39d92b8bd090627524c98b3012f0c08dc89024cfdaa7c9c98cb5fd4359376
ARG BUN_SHA256_ARM64=68b7dcd86a35e7d5e156b37e4cef4b4ab6d6b37fd2179570c0e815f13890febd
ARG GHQ_VERSION=1.8.0
ARG GHQ_SHA256_AMD64=ad0ec7b2f52312dca85f35b5c9e88a77447c2c71babbd9dfeb569ab369b8e55f
ARG GHQ_SHA256_ARM64=982a8d0f832664b6d54a0c4089198414b97dcb33e5aed7897c5c0f0fc10e6806
ARG JJ_VERSION=0.42.0
ARG JJ_SHA256_AMD64=2d91e81d649e617a81608e7401ad1106029c15ece01ac928c4a351abef42be6a
ARG JJ_SHA256_ARM64=bc962ac57ec264541a62ed8492f080898380a277222b115e1ed96163196e6fc8
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256_AMD64=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ARG ZIG_SHA256_ARM64=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17

RUN dnf -y --setopt=install_weak_deps=False install \
		bash \
		ca-certificates \
		curl \
		git \
		kcov \
		tar \
		unzip \
		xz \
	&& dnf clean all \
	&& rm -rf /var/cache/dnf

RUN set -eu; \
	case "${TARGETARCH}" in \
		amd64) bun_arch="x64"; bun_sha="${BUN_SHA256_AMD64}"; ghq_arch="amd64"; ghq_sha="${GHQ_SHA256_AMD64}"; jj_arch="x86_64"; jj_sha="${JJ_SHA256_AMD64}"; zig_arch="x86_64"; zig_sha="${ZIG_SHA256_AMD64}" ;; \
		arm64) bun_arch="aarch64"; bun_sha="${BUN_SHA256_ARM64}"; ghq_arch="arm64"; ghq_sha="${GHQ_SHA256_ARM64}"; jj_arch="aarch64"; jj_sha="${JJ_SHA256_ARM64}"; zig_arch="aarch64"; zig_sha="${ZIG_SHA256_ARM64}" ;; \
		*) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
	esac; \
	bun_url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}.zip"; \
	curl -fsSL "${bun_url}" -o /tmp/bun.zip; \
	echo "${bun_sha}  /tmp/bun.zip" | sha256sum -c -; \
	unzip -q /tmp/bun.zip -d /tmp; \
	install -m 0755 "/tmp/bun-linux-${bun_arch}/bun" /usr/local/bin/bun; \
	rm -rf /tmp/bun.zip "/tmp/bun-linux-${bun_arch}"; \
	ghq_url="https://github.com/x-motemen/ghq/releases/download/v${GHQ_VERSION}/ghq_linux_${ghq_arch}.zip"; \
	curl -fsSL "${ghq_url}" -o /tmp/ghq.zip; \
	echo "${ghq_sha}  /tmp/ghq.zip" | sha256sum -c -; \
	unzip -q /tmp/ghq.zip -d /tmp; \
	install -m 0755 "/tmp/ghq_linux_${ghq_arch}/ghq" /usr/local/bin/ghq; \
	rm -rf /tmp/ghq.zip "/tmp/ghq_linux_${ghq_arch}"; \
	jj_url="https://github.com/jj-vcs/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-${jj_arch}-unknown-linux-musl.tar.gz"; \
	curl -fsSL "${jj_url}" -o /tmp/jj.tar.gz; \
	echo "${jj_sha}  /tmp/jj.tar.gz" | sha256sum -c -; \
	tar -xzf /tmp/jj.tar.gz -C /tmp ./jj; \
	install -m 0755 /tmp/jj /usr/local/bin/jj; \
	rm -f /tmp/jj.tar.gz /tmp/jj; \
	zig_url="https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"; \
	curl -fsSL "${zig_url}" -o /tmp/zig.tar.xz; \
	echo "${zig_sha}  /tmp/zig.tar.xz" | sha256sum -c -; \
	mkdir -p /opt/zig; \
	tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
	ln -s /opt/zig/zig /usr/local/bin/zig; \
	rm /tmp/zig.tar.xz; \
	zig version; \
	ghq --version; \
	jj --version; \
	kcov --version; \
	bun --version

WORKDIR /work
