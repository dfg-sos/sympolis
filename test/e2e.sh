#!/usr/bin/env bash
# End-to-end test of Sympolis: builds the image, smoke tests its binaries, validates the workflow
# and runs it with jobs/default.yml, then checks the outputs. The CI pipeline runs the same script.
#
# By default the image is built as ghcr.io/dfg-sos/sympolis:e2e and the workflow steps are pointed
# to it by a cwltool override, so a pulled :latest image is left untouched.
set -euo pipefail

usage() {
    cat <<EOF
Usage: test/e2e.sh [--image <Image>] [--outdir <Dir>]

  --image <Image>  Tests the given image instead of building one, e.g. ghcr.io/dfg-sos/sympolis:edge
  --outdir <Dir>   Directory receiving the workflow outputs, emptied first (default: tmp/e2e)
  -h, --help       Shows this help
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYMPOLIS_IMAGE="ghcr.io/dfg-sos/sympolis"
IMAGE=""
OUTDIR="$ROOT/tmp/e2e"
BINARIES=(SympolisGraphConstruction SympolisGraphComponents SympolisSpatialClustering
          SympolisPolygonOutline SympolisEdgeVisualization SympolisMSTVisualization)
OUTPUTS=(Kahama_Small_Sympolis.gpkg Kahama_Small_Sympolis_MultiPolygons.gpkg)

while [ $# -gt 0 ]; do
    case "$1" in
        --image)  IMAGE="${2:?--image needs a value}"; shift 2 ;;
        --outdir) OUTDIR="$(realpath -m "${2:?--outdir needs a value}")"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Collapsible sections in GitHub Actions, plain headers elsewhere
section() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$1"; else printf '\n==> %s\n' "$1"; fi; }
end_section() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }
fail() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$1"; else echo "FAILED: $1" >&2; fi; exit 1; }

for cmd in docker cwltool; do
    command -v "$cmd" > /dev/null || fail "$cmd is not installed"
done
cd "$ROOT"

if [ -z "$IMAGE" ]; then
    IMAGE="$SYMPOLIS_IMAGE:e2e"
    section "Build $IMAGE"
    docker build -t "$IMAGE" .
    end_section
fi

for bin in "${BINARIES[@]}"; do
    section "Smoke test $bin"
    docker run --rm "$IMAGE" "$bin" --help || fail "$bin --help failed"
    end_section
done

section "Validate Sympolis.cwl"
cwltool --validate Sympolis.cwl
end_section

# dockerPull does not accept expressions, so every tool running the sympolis image is pointed to
# the tested image by an override keyed by the URI of the tool
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
OVERRIDES="$OUTDIR/.overrides.yml"
{
    echo "cwltool:overrides:"
    for tool in $(grep -l "dockerPull: *$SYMPOLIS_IMAGE:" "$ROOT"/cwl/*.cwl); do
        echo "  file://$tool:"
        echo "    requirements:"
        echo "      DockerRequirement:"
        echo "        dockerPull: $IMAGE"
    done
} > "$OVERRIDES"

# cwltool stages its intermediate files below /tmp by default, which a sandboxed or snap-installed
# Docker daemon cannot mount, so they are kept in the git-ignored tmp directory instead
mkdir -p "$ROOT/tmp"
WORKDIR="$(mktemp -d "$ROOT/tmp/e2e-work.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

section "Run Sympolis.cwl with jobs/default.yml"
cwltool --overrides "$OVERRIDES" --outdir "$OUTDIR" \
        --tmpdir-prefix "$WORKDIR/tmp" --tmp-outdir-prefix "$WORKDIR/out" \
        Sympolis.cwl jobs/default.yml
end_section

section "Check outputs"
for f in "${OUTPUTS[@]}"; do
    test -s "$OUTDIR/$f" || fail "Missing or empty output $f"
    # The image ships GDAL, so the outputs are read with its ogrinfo
    counts=$(docker run --rm -v "$OUTDIR:/out:ro" "$IMAGE" ogrinfo -ro -so -al "/out/$f" \
             | sed -n 's/^Feature Count: //p')
    [ -n "$counts" ] || fail "$f has no layers"
    for n in $counts; do
        [ "$n" -gt 0 ] || fail "$f has a layer without features"
    done
    echo "$f: feature counts per layer: $(echo $counts)"
done
ls -lh "$OUTDIR"
end_section

echo
echo "End-to-end test passed, outputs in $OUTDIR"
