# The udeck-plugin image: what a plugin repository's CI pulls, by digest, to
# check the repository — on GitHub Actions and on GitLab CI alike. Built by
# Scripts/make-cli.sh image, from the static musl binaries the release's Linux
# archives carry, for linux/amd64 and linux/arm64.
#
# Alpine, not scratch, because the command does not work alone:
#
#   * check and check-repo read a repository through git, which they start as
#     `/usr/bin/env git` — so git, and env at that path, have to be here;
#   * GitLab CI runs a job's script with the image's own shell, and GitHub
#     Actions keeps a `container:` job's image alive with `tail` — both need a
#     shell and its tools;
#   * the check makes its temporary files in /tmp.
#
# Nothing of Alpine is linked into the command: it is the same static binary
# as in the archives, and Alpine is only what it starts. The base is pinned by
# digest, the multi-architecture one, as the toolchain in ci.yml is: a tag can
# be moved to another build.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Git from Alpine's repository for that release, as it is when the image is
# built: its security fixes reach the next release's image, and which git an
# image holds is in the log of the job that built it (`git --version`).
#
# Git, BusyBox and others here are GPL, and an image is a copy of them: beside
# the command's own licences goes the list of every Alpine package in the
# image — its version, its licence, and the aports commit it was built from,
# where its APKBUILD is and so the source it was built from (Alpine keeps the
# source archives too, at https://distfiles.alpinelinux.org/distfiles/v3.24/).
# Made from apk's own records, here, so that it is the list of what this image
# holds rather than of what some image once held.
RUN <<'SH'
set -eu -o pipefail
apk add --no-cache git
mkdir -p /usr/share/licenses/udeck-plugin
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
' /lib/apk/db/installed | sort > /usr/share/licenses/udeck-plugin/ALPINE-PACKAGES
SH

ARG TARGETARCH
COPY ${TARGETARCH}/udeck-plugin /usr/local/bin/udeck-plugin
COPY LICENSE NOTICE THIRD_PARTY_NOTICES /usr/share/licenses/udeck-plugin/

ARG VERSION
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
