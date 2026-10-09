# The udeck-plugin image: what a plugin repository's CI pulls, by digest, to
# check the repository — on GitHub Actions and on GitLab CI alike. Built by
# Scripts/make-cli.sh image, from the static musl binaries the release's Linux
# archives carry, for linux/amd64 and linux/arm64.
#
# Alpine, not scratch, because the command does not work alone:
#
#   * check and check-repo read a repository through git, which they start as
#     `/usr/bin/env git` — so git, and env at that path, have to be here;
#   * pin reads a release through curl, started the same way: a GitLab job on
#     a runner that reaches GitHub only through a proxy pins with this image;
#   * GitLab CI runs a job's script with the image's own shell, and GitHub
#     Actions keeps a `container:` job's image alive with `tail` — both need a
#     shell and its tools;
#   * the check makes its temporary files in /tmp.
#
# Nothing of Alpine is linked into the command: it is the same static binary
# as in the archives, and Alpine is only what it starts. The base is pinned by
# digest, the multi-architecture one, as the toolchain in ci.yml is: a tag can
# be moved to another build. From Amazon ECR Public's copy of the Docker
# Official Images, the same digest, which no anonymous pull limit turns away.
FROM public.ecr.aws/docker/library/alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Git and curl from Alpine's repository for that release, as they are when the
# image is built: their security fixes reach the next release's image, and
# which git and curl an image holds is in the log of the job that built it
# (`git --version`, `curl --version`). Git already brings libcurl; curl adds
# only itself, under the curl licence libcurl is under (Alpine v3.24's main
# index, 2026-10-07). Every package either brings is in Alpine's main
# repository, where the aports links below point.
#
# Git, BusyBox and others here are under the GPL or the LGPL, and an image is
# a copy of them: beside the command's own licences goes the list of every
# Alpine package in the image — its version, its licence, and its folder in
# aports at the commit it was built from, where its APKBUILD is. Made from
# apk's own records, here, so that it is the list of what this image holds
# rather than of what some image once held. The source of every one of them
# under the GPL or the LGPL — that folder, and the upstream archives its
# APKBUILD names — is udeck-plugin-image-sources-<version>.tar, an asset of
# the release that publishes this image, and the list says so first:
# Scripts/make-cli.sh gathers the archive from this very list, read out of
# the image it built, before the image is published.
ARG VERSION
RUN <<'SH'
set -eu -o pipefail
apk add --no-cache git curl
mkdir -p /usr/share/licenses/udeck-plugin
{
    echo "# Every Alpine package in this image: its name and version, its licence, and its folder in"
    echo "# Alpine's aports at the commit it was built from, where its APKBUILD is. The source of every"
    echo "# one of them under the GPL or the LGPL -- that folder, and the upstream archives its APKBUILD"
    echo "# names -- is in"
    echo "# udeck-plugin-image-sources-$VERSION.tar, an asset of the release that published this image,"
    echo "# https://github.com/iillyyaa1997/udeck/releases/tag/v$VERSION"
    awk '
        function line() {
            if (p != "") print p " " v " | " l " | https://gitlab.alpinelinux.org/alpine/aports/-/tree/" c "/main/" o
            p = ""; v = ""; l = ""; o = ""; c = ""
        }
        /^P:/ { p = substr($0, 3) }
        /^V:/ { v = substr($0, 3) }
        /^L:/ { l = substr($0, 3) }
        /^o:/ { o = substr($0, 3) }
        /^c:/ { c = substr($0, 3) }
        /^$/ { line() }
        END { line() }
    ' /lib/apk/db/installed | sort
} > /usr/share/licenses/udeck-plugin/ALPINE-PACKAGES
SH

ARG TARGETARCH
COPY ${TARGETARCH}/udeck-plugin /usr/local/bin/udeck-plugin
COPY LICENSE NOTICE THIRD_PARTY_NOTICES /usr/share/licenses/udeck-plugin/

ARG REVISION
# Every licence in the image, the command's and Alpine's packages', as one SPDX
# expression: Scripts/make-cli.sh writes it, and refuses an image holding a
# package under a licence it does not name.
ARG LICENSES
# GitHub connects the package to the repository by the source label; the
# description and the licences are shown on the package's page.
LABEL org.opencontainers.image.title="udeck-plugin" \
      org.opencontainers.image.description="udeck-plugin ${VERSION}: checks uDeck plugins and plugin repositories, in a repository's CI" \
      org.opencontainers.image.source="https://github.com/iillyyaa1997/udeck" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.licenses="${LICENSES}"

# No ENTRYPOINT: GitLab CI hands the job's script to the image's shell, and an
# entrypoint would have to be emptied (`entrypoint: [""]`) in every
# .gitlab-ci.yml that uses it. Run with no command, it says how to use it.
CMD ["udeck-plugin", "--help"]
