#!/bin/bash
#
# This script purges old, "untagged" repositories and runs the garbage collector in Docker Registry >= 2.4.0.
# It works on the whole registry or the specified repositories.
# The optional flag -x may be used to completely remove the specified repositories or tagged images.
# This script stops the Registry container during the purge, making it temporarily unavailable to clients.
#
# v2.4 by Ricardo Branco
#
# MIT License
#

exit_usage ()
{
	echo "Usage: ${0##*/} [--dry-run] [-x] REGISTRY_CONTAINER [REPOSITORY[:TAG]]..." >&2
	exit 1
}

DOCKER=${DOCKER:-$(type -P docker)}

while [[ $1 =~ ^- ]] ; do
	case "$1" in
		--dry-run)
			run="echo" ;;
		-x)
			remove="true" ;;
		*)
			exit_usage ;;
	esac
	shift
done

if [ $# -lt 1 ] ; then
	exit_usage
fi

CONTAINER="$1"
shift

# Check Docker tag (repository & tag suffix)
check_dockertag ()
{
	local repo=${1%:*}
	local tag="latest"
	local path=($(echo ${repo//\// }))
	local elem

	if [[ $repo =~ : ]] ; then
		tag=${1#*:}
	fi

	# From https://github.com/docker/docker/blob/master/image/spec/v1.2.md
	# Tag values are limited to the set of characters [a-zA-Z0-9_.-], except they may not start with a . or - character.
	# Tags are limited to 127 characters.
	if ! [[ ${#1} -lt 256 && ${#tag} -lt 128 && $tag =~ ^[a-zA-Z0-9]+([\._-][a-zA-Z0-9_]+)*$ ]] ; then
		return 1
	fi

	# From https://github.com/docker/distribution/blob/master/docs/spec/api.md
	# 1. A repository name is broken up into path components. A component of a repository name must be at least
	#    one lowercase, alpha-numeric characters, optionally separated by periods, dashes or underscores.
	#    More strictly, it must match the regular expression [a-z0-9]+(?:[._-][a-z0-9]+)*
	# 2. If a repository name has two or more path components, they must be separated by a forward slash ("/").
	# 3. The total length of a repository name, including slashes, must be less than 256 characters.
	for elem in "${path[@]}" ; do
		if ! [[ ${#elem} -gt 0 && $elem =~ ^[a-z0-9]+([\._-][a-z0-9]+)*$ ]] ; then
			return 1
		fi
	done
}

for image ; do
	if ! check_dockertag "$image" ; then
		echo "Invalid Docker repository/tag: $image" 1>&2
		exit 1
	fi
done

# We don't want to remove the whole registry. Check that -x is specified with repositories.
if [ $# -lt 1 -a "$remove" = "true" ] ; then
	echo "ERROR: The -x option requires that you specify at least one repository..." >&2
	exit_usage
fi

# Check that we're root
if [ $(id -u) != 0 ] ; then
	echo "ERROR: You must run this script as root" >&2
	exit 1
fi

# Check that Docker is installed
if [ -z "$DOCKER" ] ; then
	echo "ERROR: You must install Docker!"
	exit 1
fi

# Check that we are running at least Docker >= 1.8.0 (for "docker inspect --type")
if [[ -z $($DOCKER version -f '{{ .Client.Version }}' 2>/dev/null) ]] ; then
	echo "ERROR: You must be running Docker >= 1.8.0" >&2
	exit 1
fi

# Check that the container is an instance of the registry:2 image
image=$($DOCKER inspect --type container -f '{{ .Config.Image }}' "$CONTAINER")
if [ -z "$image" ] ; then
	exit 1
fi

if [ "$image" != "registry:2" ] ; then
	echo "ERROR: The container $CONTAINER is not running the registry:2 image" >&2
	exit 1
fi

# Check that the image (and repository format) is 2.4.0+
if [[ $($DOCKER run --rm registry:2 --version | awk '{ print $3 }' | tr -d v.) -lt 240 ]] ; then
	echo "ERROR: You're not running Docker Registry 2.4.0+" >&2
	exit 1
fi

# Get the Registry local directory from the container itself

# Use $REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY if defined
REGISTRY_DIR=$($DOCKER inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | \
	sed -rn 's/^REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=(.*)/\1/p')

# Otherwise extract it from the YAML config
[ -z "$REGISTRY_DIR" ] && \
REGISTRY_DIR=$($DOCKER cp "$CONTAINER":/etc/docker/registry/config.yml - | \
	sed -rne '/^storage:/,/^[a-z]/p' | sed -rne '/^[[:blank:]]+filesystem:/,$s/^[[:blank:]]+rootdirectory:[[:blank:]]+(.*)/\1/p')

if [ -z "$REGISTRY_DIR" ] ; then
	echo "ERROR: Unsupported storage driver" >&2
	exit 1
fi

REGISTRY_DIR=$($DOCKER inspect -f '{{range .Mounts}}{{println .Source .Destination}}{{end}}' "$CONTAINER" |
	awk -v dir="$REGISTRY_DIR" '$2 == dir { print $1 }')

cd "$REGISTRY_DIR/docker/registry/v2/repositories/" || exit 1

# Stop container
$run $DOCKER stop "$CONTAINER" >/dev/null

clean_revisions ()
{
	local repo="$1"

	comm -23 <(ls $repo/_manifests/revisions/sha256/) \
		<(find $repo/_manifests/tags/ -type d -regextype egrep -regex '.*/sha256/[0-9a-f]+$' -printf '%f\n' | sort -u) | \
	sed "s%^%$repo/_manifests/revisions/sha256/%" | \
	xargs -r $run rm -rvf
}

# Clean a specific repo:tag
clean_tag ()
{
	local repo="$1"
	local tag="$2"
	local current

	if [ ! -f "$repo/_manifests/tags/$tag/current/link" ] ; then
		echo "ERROR: No such tag: $tag in repository $repo" >&2
		return 1
	fi

	if [[ $remove == true ]] ; then
		$run rm -rvf "$repo/_manifests/tags/$tag/"
	else
		current=$(< "$repo/_manifests/tags/$tag/current/link")
		current=${current#"sha256:"}
		find "$repo/_manifests/tags/$tag/index/sha256/" -mindepth 1 -type d ! -name $current -exec $run rm -rvf {} +
		clean_revisions "$repo"
	fi
}

# Clean all tags (or a specific one, if specified) from a specific repository
clean_repo ()
{
	local repo="${1%:*}"
	local tags=$(ls "$repo/_manifests/tags/" 2>/dev/null)
	local tag
	local current

	declare -A currents

	if [ ! -d "$repo" ] ; then
		echo "ERROR: No such repository: $repo" >&2
		return 1
	fi

	if [[ $1 =~ : ]] ; then
		tag=${1#*:}
	fi

	if [[ $remove == true && ( -z $tag || $tag == $tags ) ]] ; then
		$run rm -rvf "$repo"
		return
	fi

	if [ -z "$tag" ] ; then
		for link in $repo/_manifests/tags/*/current/link ; do
			current=$(< $link)
			current=${current#"sha256:"}
			currents[$current]="x"
		done

		find $repo/_manifests/tags/ -type d -regextype egrep -regex '.*/sha256/[0-9a-f]+$' | \
		while read d ; do
			hash=${d##*/}
			[ -z "${currents[$hash]}" ] && echo $d
		done | \
		$run xargs -r rm -rvf

		clean_revisions "$repo"
	else
		clean_tag "$repo" "$tag" || let errors++
	fi
}

# Clean all or specified images/repositories
for image in ${@:-$(ls .)} ; do
	clean_repo "$image" || let errors++
done

$DOCKER run --rm -e REGISTRY_STORAGE_DELETE_ENABLE=true -v "$REGISTRY_DIR:/var/lib/registry" registry:2 garbage-collect /etc/docker/registry/config.yml $run

# Restart registry
$run $DOCKER start "$CONTAINER" >/dev/null

exit $errors
