#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "apply-templates.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#

FROM debian:trixie-slim

RUN set -eux; \
	apt-get install --update -y --no-install-recommends \
		ca-certificates \
# DOCKER_HOST=ssh://... -- https://github.com/docker/cli/pull/1014
		openssh-client \
# https://github.com/docker-library/docker/issues/482#issuecomment-2197116408
# TODO "git" is intentionally omitted (for now) because on Debian it balloons the image size considerably, mostly thanks to a Perl dependency -- https://github.com/docker-library/docker/issues/306#issuecomment-2946402034
	; \
	\
# https://docs.docker.com/engine/install/debian/
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get install -y --no-install-recommends gnupg; \
	\
	GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
	mkdir -p /usr/local/share/keyrings/; \
	gpg --batch --keyserver keyserver.ubuntu.com --recv-keys 9DC858229FC7DD38854AE2D88D81803C0EBFCD88; \
	gpg --batch --export --armor 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 > /usr/local/share/keyrings/docker.asc; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME"; \
	\
	{ \
		echo 'Types: deb'; \
		echo 'URIs: https://download.docker.com/linux/debian'; \
		echo 'Suites: trixie'; \
		echo 'Components: stable'; \
		echo 'Signed-By: /usr/local/share/keyrings/docker.asc'; \
	} > /etc/apt/sources.list.d/docker.sources; \
	\
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	apt-get dist-clean; \
	\
# pre-add a "docker" group for socket usage (the "docker-ce" package would create this too, but this allows us to control the GID that gets selected)
	groupadd --gid 2375 --system docker

ENV DOCKER_VERSION 29.10.0
RUN set -eux; \
	apt-get install --update -y --no-install-recommends 'docker-ce-cli=5:29.10.0-1~debian.13~trixie'; \
	apt-get dist-clean; \
	\
	docker --version

ENV DOCKER_BUILDX_VERSION 0.39.1
RUN set -eux; \
	apt-get install --update -y --no-install-recommends 'docker-buildx-plugin=0.39.1-1~debian.13~trixie'; \
	apt-get dist-clean; \
	\
	docker buildx version

ENV DOCKER_COMPOSE_VERSION 5.8.0
RUN set -eux; \
	apt-get install --update -y --no-install-recommends 'docker-compose-plugin=5.8.0-1~debian.13~trixie'; \
	apt-get dist-clean; \
	\
# TODO why isn't this symlink part of the package?
	ln -svfT /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose; \
	docker-compose --version; \
	docker compose version

COPY modprobe.sh /usr/local/bin/modprobe
COPY docker-entrypoint.sh /usr/local/bin/

# https://github.com/docker-library/docker/pull/166
#   dockerd-entrypoint.sh uses DOCKER_TLS_CERTDIR for auto-generating TLS certificates
#   docker-entrypoint.sh uses DOCKER_TLS_CERTDIR for auto-setting DOCKER_TLS_VERIFY and DOCKER_CERT_PATH
# (For this to work, at least the "client" subdirectory of this path needs to be shared between the client and server containers via a volume, "docker cp", or other means of data sharing.)
ENV DOCKER_TLS_CERTDIR=/certs
# also, ensure the directory pre-exists and has wide enough permissions for "dockerd-entrypoint.sh" to create subdirectories, even when run in "rootless" mode
RUN mkdir /certs /certs/client && chmod 1777 /certs /certs/client
# (doing both /certs and /certs/client so that if Docker does a "copy-up" into a volume defined on /certs/client, it will "do the right thing" by default in a way that still works for rootless users)

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["sh"]
