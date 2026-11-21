#!/usr/bin/env bash
set -Eeuo pipefail

# https://docs.docker.com/engine/install/debian/
debUrl='https://download.docker.com/linux/debian'
debSuite='trixie' # this is also the suite of the "debian" image we are FROM

# bashbrew arch to dpkg arch (for the architectures Docker publishes ".deb" files for)
declare -A dpkgArches=(
	['amd64']='amd64'
	['arm32v7']='armhf'
	['arm64v8']='arm64'
	['ppc64le']='ppc64el'
	['s390x']='s390x'
)
# Docker does not publish ".deb" files for Windows, so those still come from the static binary downloads (and the "windows-amd64" release asset of each plugin)
windowsArch='windows-amd64'
export windowsArch
windowsDockerArch='x86_64'

# the packages we install, so we only bother parsing those out of the (huge) "Packages" files
debPackages='[ "docker-ce", "docker-ce-cli", "docker-ce-rootless-extras", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin" ]'

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
	json='{}'
else
	json="$(< versions.json)"
fi
versions=( "${versions[@]%/}" )

scriptPid="$$" # so we can kill the script even from a subshell
_curl() {
	exec 42>&1
	local code
	code="$(curl --silent --location -o /dev/fd/42 --write-out '%{http_code}' "$@")"
	case "$code" in
		200) return 0 ;;
		404) return 1 ;;
	esac
	echo >&2 "error: unexpected status code $code while fetching: $*"
	kill "$scriptPid"
	exit 1
}

# prints a JSON object of "package name" -> [ versions, highest first ] for the given component ("stable" or "test") and architecture of Docker's apt repository
_debIndex() {
	local component="$1"; shift
	local dpkgArch="$1"; shift

	local packages
	packages="$(_curl "$debUrl/dists/$debSuite/$component/binary-$dpkgArch/Packages.gz" | gunzip)" || return "$?"

	# "Package: foo" and "Version: 1.2.3-1" lines for each stanza, filtered down to the packages we care about
	local tsv
	tsv="$(
		jq <<<"$packages" --raw-input --slurp --raw-output --argjson wanted "$debPackages" '
			split("\n\n")[]
			| (
				capture("(^|\n)Package: (?<package>[^\n]+)")
				+ capture("(^|\n)Version: (?<version>[^\n]+)")
			)?
			| select(.package | IN($wanted[]))
			| [ .package, .version ]
			| @tsv
		' \
			| sort --field-separator=$'\t' --key=1,1 --key=2,2Vr # (a key with its own ordering flags ignores the global "--reverse", so the "r" has to be on the key)
	)" || return "$?"

	jq <<<"$tsv" --compact-output --raw-input --null-input '
		reduce (inputs | split("\t")) as [ $package, $version ] ({}; .[$package] += [ $version ])
	'
}

declare -A debIndexes=()
# caches the output of "_debIndex" (it is ~10 MiB of text to download and parse, and we ask for the same ones repeatedly)
debIndex() {
	local component="$1"; shift
	local dpkgArch="$1"; shift
	local key="$component/$dpkgArch"
	if [ -z "${debIndexes["$key"]:-}" ]; then
		# an architecture that is not published at all (yet) is the same as an architecture with nothing in it
		debIndexes["$key"]="$(_debIndex "$component" "$dpkgArch" || echo '{}')"
	fi
	echo "${debIndexes["$key"]}"
}

dindLatest="$(
	_curl -H 'Accept: application/json' 'https://github.com/moby/moby/commits/master/hack/dind.atom' \
		| jq -r '.payload | first(.. | .commits?[]?.oid)'
)"

# Windows does not have ".deb" files to use, so these are the standalone "windows-amd64" binaries for each plugin from their GitHub releases (and we throw the rest of the architectures away)
buildxVersions="$(
	git ls-remote --tags https://github.com/docker/buildx.git \
		| jq --raw-input --null-input --raw-output '
			[ inputs | capture("refs/tags/v(?<version>[0-9.]+)($|\\^)") | .version ]
			| unique_by( split(".") | map(tonumber? // .) )
			| reverse[]
		'
)"
buildx=
buildxVersion=
for buildxVersion in $buildxVersions; do
	# checksums.txt -> linux + *bsd checksums
	# checksums-signed.txt -> windows + darwin checksums (see also https://github.com/docker/buildx/pull/3978)
	# fail if one is missing
	if \
		checksums="$(_curl "https://github.com/docker/buildx/releases/download/v${buildxVersion}/checksums.txt")" \
		&& checksums+=$'\n' \
		&& checksums+="$(_curl "https://github.com/docker/buildx/releases/download/v${buildxVersion}/checksums-signed.txt")" \
	; then
		buildx="$(jq <<<"$checksums" -csR --arg version "$buildxVersion" --arg arch "$windowsArch" '
			rtrimstr("\n") | split("\n")
			| map(
				split(" [ *]?"; "")
				| {
					sha256: .[0],
					file: .[1],
					url: ("https://github.com/docker/buildx/releases/download/v" + $version + "/" + .[1]),
				}
				| select(.file | test("[.]windows-amd64[.]exe$"))
				| { ($arch): . }
			)
			| add
			| {
				version: $version,
				arches: .,
			}
		')"
		break
	fi
done
if [ -z "$buildx" ] || ! jq <<<"$buildx" -e '.arches[env.windowsArch]' > /dev/null; then
	echo >&2 'error: failed to determine buildx version!'
	exit 1
fi

composeVersions="$(
	git ls-remote --tags https://github.com/docker/compose.git \
		| jq --raw-input --null-input --raw-output '
			[ inputs | capture("refs/tags/v(?<version>[0-9.]+)($|\\^)") | .version ]
			| unique_by( split(".") | map(tonumber? // .) )
			| reverse[]
		'
)"
compose=
composeVersion=
for composeVersion in $composeVersions; do
	if checksums="$(_curl "https://github.com/docker/compose/releases/download/v${composeVersion}/checksums.txt")"; then
		compose="$(jq <<<"$checksums" -csR --arg version "$composeVersion" --arg arch "$windowsArch" '
			rtrimstr("\n") | split("\n")
			| map(
				split(" *")
				| {
					sha256: .[0],
					file: .[1],
					url: ("https://github.com/docker/compose/releases/download/v" + $version + "/" + .[1]),
				}
				| select(.file | test("-windows-x86_64[.]exe$"))
				| { ($arch): . }
			)
			| add
			| {
				version: $version,
				arches: .,
			}
		')"
		break
	fi
done
if [ -z "$compose" ] || ! jq <<<"$compose" -e '.arches[env.windowsArch]' > /dev/null; then
	echo >&2 'error: failed to determine compose version!'
	exit 1
fi

for version in "${versions[@]}"; do
	rcVersion="${version%-rc}"
	export version rcVersion
	channel='stable' # this is also the name of the component in Docker's apt repository
	rc='false'
	if [ "$rcVersion" != "$version" ]; then
		channel='test'
		rc='true'
	fi

	# the highest version of "docker-ce" (and thus "docker-ce-cli" and "docker-ce-rootless-extras") in this channel for this release series (RCs and GA releases are separate here, just like the "-rc" entries in "versions.json")
	deb="$(
		debIndex "$channel" amd64 \
			| jq --compact-output --arg url "$debUrl" --arg suite "$debSuite" --arg component "$channel" --arg rcVersion "$rcVersion" --argjson rc "$rc" '
				def upstream_version: sub("^[0-9]+:"; "") | sub("-[^-]*$"; "");
				first(
					.["docker-ce"][]?
					| select(
						upstream_version
						| startswith($rcVersion + ".")
						and (contains("~") == $rc)
					)
				) as $engine
				| {
					url: $url,
					suite: $suite,
					component: $component,
					packages: {
						engine: { package: "docker-ce", version: $engine },
						cli: { package: "docker-ce-cli", version: $engine },
						containerd: { package: "containerd.io", version: .["containerd.io"][0] },
						buildx: { package: "docker-buildx-plugin", version: .["docker-buildx-plugin"][0] },
						compose: { package: "docker-compose-plugin", version: .["docker-compose-plugin"][0] },
						rootless: { package: "docker-ce-rootless-extras", version: $engine },
					},
				}
			'
	)"

	if [ -z "$deb" ]; then
		if currentNull="$(jq -r '.[env.version] == null' versions.json)" && [ "$currentNull" = 'true' ]; then
			echo >&2 "warning: skipping '$version' (does not appear to be released yet)"
			json="$(jq <<<"$json" -c '.[env.version] = null')"
			continue
		fi
		echo >&2 "error: cannot find full version for $version"
		exit 1
	fi

	# "5:29.10.0~rc.1-1~debian.13~trixie" -> "29.10.0-rc.1"
	fullVersion="$(jq <<<"$deb" --raw-output '.packages.engine.version | sub("^[0-9]+:"; "") | sub("-[^-]*$"; "") | gsub("~"; "-")')"

	# if this is a "-rc" release, let's make sure the release it contains isn't already GA (and thus something we should not publish anymore)
	if [ "$rcVersion" != "$version" ] && rcFullVersion="$(jq <<<"$json" -r '.[env.rcVersion].version // ""')" && [ -n "$rcFullVersion" ]; then
		latestVersion="$({ echo "$fullVersion"; echo "$rcFullVersion"; } | sort -V | tail -1)"
		if [[ "$fullVersion" == "$rcFullVersion"* ]] || [ "$latestVersion" = "$rcFullVersion" ]; then
			# "x.y.z-rc1" == x.y.z*
			echo >&2 "warning: skipping/removing '$version' ('$rcVersion' is at '$rcFullVersion' which is newer than '$fullVersion')"
			json="$(jq <<<"$json" -c '.[env.version] = null')"
			continue
		fi
	fi

	jq <<<"$deb" --raw-output --arg fullVersion "$fullVersion" '
		.packages
		| "\(env.version): \($fullVersion) (containerd \(.containerd.version), buildx \(.buildx.version), compose \(.compose.version))"
	'

	export fullVersion dindLatest
	doc="$(
		jq -nc --argjson deb "$deb" --argjson buildx "$buildx" --argjson compose "$compose" '{
			version: env.fullVersion,
			arches: {},
			dind: { version: env.dindLatest },
			deb: $deb,
			buildx: $buildx,
			compose: $compose,
		}'
	)"

	declare -A hasArches=()
	packages="$(jq <<<"$deb" -c '.packages')"
	for bashbrewArch in "${!dpkgArches[@]}"; do
		dpkgArch="${dpkgArches["$bashbrewArch"]}"

		# not every architecture is updated in lockstep, so we only publish the architectures that have *everything* we need at the exact versions we chose (and the rest will come back on their own once they catch up)
		if ! debIndex "$channel" "$dpkgArch" | jq --exit-status --argjson packages "$packages" '
			. as $index
			| $packages
			| all(.[]; . as $p | any($index[$p.package][]?; . == $p.version))
		' > /dev/null; then
			echo >&2 "warning: skipping '$bashbrewArch' for '$version' (missing at least one of the expected packages)"
			continue
		fi

		export bashbrewArch dpkgArch
		doc="$(
			jq <<<"$doc" -c '.arches[env.bashbrewArch] = {
				dpkgArch: env.dpkgArch,
			}'
		)"
		hasArches["$bashbrewArch"]=1
	done

	# check whether Windows is supported for this release
	url="https://download.docker.com/win/static/$channel/$windowsDockerArch/docker-$fullVersion.zip"
	if _curl --head "$url" > /dev/null; then
		if sha256="$(_curl "$url.sha256")"; then
			sha256="${sha256%% *}"
			if [[ ! "$sha256" =~ ^[[:xdigit:]]{64}$ ]]; then
				echo >&2 "error: invalid checksum for $url: '$sha256'"
				exit 1
			fi
		else
			sha256=
		fi

		export url sha256
		doc="$(
			jq <<<"$doc" -c '
				.arches[env.windowsArch] = { dockerUrl: env.url }
				| if env.sha256 != "" then
					.arches[env.windowsArch].dockerSha256 = env.sha256
				end
			'
		)"
		hasArches["$windowsArch"]=1
	fi

	for alwaysExpectedArch in amd64 arm64v8; do
		if [ -z "${hasArches["$alwaysExpectedArch"]:-}" ]; then
			echo >&2 "error: missing '$alwaysExpectedArch' for '$version'; cowardly refusing to continue! (because this is almost always a scraping flake or similar bug)"
			exit 1
		fi
	done

	# order here controls the order of the library/ file
	for variant in \
		cli \
		dind \
		dind-rootless \
		windows/windowsservercore-ltsc2025 \
		windows/windowsservercore-ltsc2022 \
	; do
		base="${variant%%/*}" # "buster", "windows", etc.
		if [ "$base" = 'windows' ] && [ -z "${hasArches["$windowsArch"]:-}" ]; then
			continue
		fi
		export variant
		doc="$(jq <<<"$doc" -c '.variants += [ env.variant ]')"
	done

	json="$(jq <<<"$json" -c --argjson doc "$doc" '
		.[env.version] = $doc
		# make sure both "XX.YY" and "XX.YY-rc" always exist
		| .[env.rcVersion] //= null
		| .[env.rcVersion + "-rc"] //= null
	')"
done

jq <<<"$json" -S . > versions.json
