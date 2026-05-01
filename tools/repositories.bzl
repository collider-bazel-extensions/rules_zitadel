"""Maintainer-only chart fetch."""

load("//tools:versions.bzl", "ZITADEL_CHART_VERSIONS")

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(["**/*"]),
)
"""

def _impl(rctx):
    version = rctx.attr.version
    if version not in ZITADEL_CHART_VERSIONS:
        fail("rules_zitadel: unknown chart version '{}'. Known: {}".format(
            version,
            sorted(ZITADEL_CHART_VERSIONS.keys()),
        ))
    pin = ZITADEL_CHART_VERSIONS[version]
    rctx.download_and_extract(
        url = pin["chart_url"],
        sha256 = pin["chart_sha256"],
    )
    rctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(rctx.name))
    rctx.file("BUILD.bazel", _BUILD)

zitadel_chart_repository = repository_rule(
    implementation = _impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
)
