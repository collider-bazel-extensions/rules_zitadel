"""Maintainer-side: chart .tgz pin.

Zitadel publishes their chart at `charts.zitadel.com`. The release
artifacts mirror to `github.com/zitadel/zitadel-charts/releases`,
which is what we pin against (slightly more stable URL contract).
"""

ZITADEL_CHART_VERSIONS = {
    "9.34.0": {
        "chart_url": "https://github.com/zitadel/zitadel-charts/releases/download/zitadel-9.34.0/zitadel-9.34.0.tgz",
        "chart_sha256": "b107a0770b78adfa6ee2364e7bcdc64d718990a5c4d103a1a63819b496ef4ce9",
    },
}
