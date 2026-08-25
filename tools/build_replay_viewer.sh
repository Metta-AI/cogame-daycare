#!/usr/bin/env bash
# The `coworld build` replay-viewer hook. Compiles the SAME sim module to wasm
# (replay-viewer/daycare_replay.nim, emscripten) inside the pinned
# emscripten/emsdk container and copies the finished bundle to the requested
# output directory. Paintbot's hook with three changes:
#   - the image tag is coworld-daycare-replay-viewer-build
#   - the `docker cp` source is /workspace/daycare/replay-viewer/dist/.
#   - the output parent is `mkdir -p`ed BEFORE the containment check, because
#     `coworld build` pre-creates it and CI does not (ecos, 2026-08-23): the
#     inherited `cd "$(dirname ...)"` exits 1 on a fresh checkout otherwise.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

requested_output="$1"

if [[ "${requested_output}" != /* || "$(basename "${requested_output}")" != "static-replay-viewer" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

# The inherited bug: this `cd` needs the parent to exist already.
mkdir -p "$(dirname "${requested_output}")"
output_parent="$(cd "$(dirname "${requested_output}")" && pwd -P)"
output_dir="${output_parent}/static-replay-viewer"
if [[ "${output_dir}" != "${repo_dir}"/* || -L "${output_dir}" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"

image_tag="coworld-daycare-replay-viewer-build:$$"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  docker image rm "${image_tag}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_args=(
  --platform linux/amd64
  --file "${repo_dir}/Dockerfile.replay-viewer"
  --target replay-viewer-builder
  --tag "${image_tag}"
  "${repo_dir}"
)
if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load "${build_args[@]}"
else
  docker build "${build_args[@]}"
fi
container_id="$(docker create --platform linux/amd64 "${image_tag}")"
docker cp "${container_id}:/workspace/daycare/replay-viewer/dist/." "${output_dir}"

test -f "${output_dir}/index.html"
