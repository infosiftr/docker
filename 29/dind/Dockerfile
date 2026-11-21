#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "apply-templates.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#

FROM docker:29-cli

# Runtime dependencies:
# - https://github.com/moby/moby/blob/864598f8c2677189e308eb4a3b3c0dd41fc06599/project/PACKAGERS.md#runtime-dependencies#runtime-dependencies
# - https://github.com/docker/packaging/blob/0ba325d178593583f190dc91566214a85c3880ad/pkg/docker-engine/deb/control#L24-L36
# ("docker-ce" itself "Depends" on "containerd.io", "iptables", and "nftables", but only "Recommends" the rest; "iptables" is explicit here because we need it for the "iptables-legacy" bits below, which come before "docker-ce")
RUN set -eux; \
	apt-get install --update -y --no-install-recommends \
		iptables \
# our "modprobe" wrapper falls back to the real "modprobe" (and uses "lsmod"), which Alpine gets from busybox but Debian only has in "kmod"
		kmod \
		openssl \
# pigz: https://github.com/moby/moby/pull/35697 (faster gzip implementation)
		pigz \
# "docker top" needs "ps"
		procps \
		uidmap \
		xz-utils \
	; \
	apt-get dist-clean

# dind might be used on systems where the nf_tables kernel module isn't available. In that case,
# we need to switch over to xtables-legacy. See https://github.com/docker-library/docker/issues/463
RUN set -eux; \
# set up a symlink farm we can use PATH to switch to legacy with
	mkdir -p /usr/local/sbin/.iptables-legacy; \
	for f in \
		iptables \
		iptables-save \
		iptables-restore \
		ip6tables \
		ip6tables-save \
		ip6tables-restore \
	; do \
# "iptables-save" -> "iptables-legacy-save", "ip6tables" -> "ip6tables-legacy", etc.
		prefix="${f%%-*}"; \
		b="$(command -v "$prefix-legacy${f#$prefix}")"; \
		"$b" --version; \
		ln -svT "$b" "/usr/local/sbin/.iptables-legacy/$f"; \
	done; \
# verify it works (and gets us legacy)
	export PATH="/usr/local/sbin/.iptables-legacy:$PATH"; \
	iptables --version | grep legacy

# set up subuid/subgid so that "--userns-remap=default" works out-of-the-box
RUN set -eux; \
	groupadd --system dockremap; \
	useradd --system --gid dockremap --shell /usr/sbin/nologin dockremap; \
	echo 'dockremap:165536:65536' >> /etc/subuid; \
	echo 'dockremap:165536:65536' >> /etc/subgid

RUN set -eux; \
	apt-get install --update -y --no-install-recommends \
		'docker-ce=5:29.10.0-1~debian.13~trixie' \
# "docker-ce" "Depends" on "containerd.io", so we pin it explicitly to keep what that resolves to reproducible
		'containerd.io=2.4.2-4~debian.13~trixie' \
	; \
	apt-get dist-clean; \
	\
# "dockerd-entrypoint.sh" expects "docker-init" (tini) in PATH, but the package only puts it in "/usr/libexec/docker"
	ln -svT /usr/libexec/docker/docker-init /usr/local/bin/docker-init; \
	docker-init --version; \
	\
	dockerd --version; \
	containerd --version; \
	ctr --version; \
	runc --version

# https://github.com/moby/moby/tree/master/hack/dind
ENV DIND_COMMIT 8d9e3502aba39127e4d12196dae16d306f76993d

RUN set -eux; \
# "wget" is only needed long enough to download "dind"
	apt-get install --update -y --no-install-recommends wget; \
	wget -O /usr/local/bin/dind "https://raw.githubusercontent.com/moby/moby/${DIND_COMMIT}/hack/dind"; \
	chmod +x /usr/local/bin/dind; \
	apt-get purge -y --auto-remove wget; \
	apt-get dist-clean

COPY dockerd-entrypoint.sh /usr/local/bin/

VOLUME /var/lib/docker
EXPOSE 2375 2376

ENTRYPOINT ["dockerd-entrypoint.sh"]
CMD []
