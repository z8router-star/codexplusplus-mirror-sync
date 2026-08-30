#!/usr/bin/env bash
set -euo pipefail

: "${R2_ACCOUNT_ID:?Set the CLOUDFLARE_ACCOUNT_ID repository secret}"
: "${R2_ACCESS_KEY_ID:?Set the R2_ACCESS_KEY_ID repository secret}"
: "${R2_SECRET_ACCESS_KEY:?Set the R2_SECRET_ACCESS_KEY repository secret}"
: "${R2_BUCKET:?Set the R2_BUCKET repository variable}"
: "${R2_PUBLIC_BASE_URL:?Set the R2_PUBLIC_BASE_URL repository variable}"
: "${MIRROR_ID:?Set MIRROR_ID (for example codex-mirror)}"
: "${MIRROR_REPOSITORY:?Set MIRROR_REPOSITORY (for example z8hk/codex-mirror)}"
: "${UPSTREAM_REPOSITORY:?Set UPSTREAM_REPOSITORY}"
: "${UPSTREAM_RELEASE_URL:?Set UPSTREAM_RELEASE_URL}"
: "${MIRROR_TAG:?Set MIRROR_TAG}"
: "${MIRROR_VERSION:?Set MIRROR_VERSION}"
: "${ASSET_SPEC_FILE:?Set ASSET_SPEC_FILE}"

RAW_PART_BYTES="${RAW_PART_BYTES:-50331648}"
UPLOAD_PARALLELISM="${UPLOAD_PARALLELISM:-8}"
VERIFY_PARALLELISM="${VERIFY_PARALLELISM:-8}"
R2_PUBLIC_BASE_URL="${R2_PUBLIC_BASE_URL%/}"
R2_PREFIX="${R2_PREFIX:-z8-launch/${MIRROR_ID}/${MIRROR_TAG}}"
R2_LATEST_KEY="${R2_LATEST_KEY:-z8-launch/${MIRROR_ID}/latest.json}"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
# AWS CLI only reads the standard credential variable names. Keep the
# workflow-facing R2 names while mapping them in memory for every S3 call.
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"

for required_command in aws curl jq split sha256sum stat xargs; do
  command -v "${required_command}" >/dev/null 2>&1 || {
    echo "::error::Required command is unavailable: ${required_command}"
    exit 1
  }
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

[[ "${R2_ACCOUNT_ID}" =~ ^[A-Fa-f0-9]{32}$ ]]
[[ "${R2_BUCKET}" =~ ^[A-Za-z0-9._-]{1,63}$ ]]
[[ "${R2_PUBLIC_BASE_URL}" == "https://download.z8.hk" ]]
[[ "${MIRROR_ID}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
[[ "${MIRROR_REPOSITORY}" =~ ^[A-Za-z0-9._-]{1,64}/[A-Za-z0-9._-]{1,128}$ ]]
[[ "${R2_PREFIX}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]
[[ "${R2_LATEST_KEY}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]
[[ "${MIRROR_TAG}" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "${MIRROR_VERSION}" =~ ^[A-Za-z0-9._-]+$ ]]
case "${MIRROR_ID}:${MIRROR_REPOSITORY}" in
  codex-mirror:z8hk/codex-mirror|codexplusplus-mirror:z8hk/codexplusplus-mirror) ;;
  *)
    echo "::error::Mirror ID and logical repository do not match"
    exit 1
    ;;
esac
[[ "${R2_PREFIX}" == "z8-launch/${MIRROR_ID}/${MIRROR_TAG}" ]]
[[ "${R2_LATEST_KEY}" == "z8-launch/${MIRROR_ID}/latest.json" ]]
[[ "${RAW_PART_BYTES}" =~ ^[1-9][0-9]*$ ]]
[[ "${UPLOAD_PARALLELISM}" =~ ^[1-9][0-9]*$ ]]
[[ "${VERIFY_PARALLELISM}" =~ ^[1-9][0-9]*$ ]]
jq -e 'type == "array" and length > 0 and length <= 8' "${ASSET_SPEC_FILE}" >/dev/null

normalized_assets="${work}/assets.json"
jq -c 'map({filename, path, upstreamUrl, sizeBytes, sha256:(.sha256 | ascii_downcase)})' \
  "${ASSET_SPEC_FILE}" > "${normalized_assets}"

while IFS=$'\t' read -r filename path upstream_url expected_size expected_sha; do
  [[ "${filename}" =~ ^[A-Za-z0-9._-]+$ ]]
  [[ "${upstream_url}" == https://* ]]
  [[ -f "${path}" ]]
  [[ "${expected_size}" =~ ^[1-9][0-9]*$ ]]
  [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]]
  actual_size="$(stat -c '%s' "${path}")"
  actual_sha="$(sha256sum "${path}" | awk '{print tolower($1)}')"
  [[ "${actual_size}" == "${expected_size}" ]]
  [[ "${actual_sha}" == "${expected_sha}" ]]
done < <(jq -r '.[] | [.filename,.path,.upstreamUrl,(.sizeBytes|tostring),.sha256] | @tsv' "${normalized_assets}")

latest_url="${R2_PUBLIC_BASE_URL}/${R2_LATEST_KEY}"
public_prefix="${R2_PUBLIC_BASE_URL}/"
versioned_latest_url="${public_prefix}${R2_PREFIX}/latest.json"

manifest_matches_assets() {
  local manifest_file="$1"
  local versioned_prefix="${public_prefix}${R2_PREFIX}/"
  jq -e \
    --arg repository "${MIRROR_REPOSITORY}" \
    --arg tag "${MIRROR_TAG}" \
    --arg version "${MIRROR_VERSION}" \
    --arg prefix "${versioned_prefix}" \
    --slurpfile expected "${normalized_assets}" '
      . as $manifest |
      $manifest.schemaVersion == 3 and
      $manifest.mirrorProvider == "cloudflare_r2" and
      $manifest.mirrorRepository == $repository and
      $manifest.tag == $tag and
      $manifest.version == $version and
      ($manifest.assets | length) == ($expected[0] | length) and
      all($expected[0][];
        . as $asset |
        any($manifest.assets[];
          .filename == $asset.filename and
          .sizeBytes == $asset.sizeBytes and
          (.sha256 | ascii_downcase) == $asset.sha256 and
          (.parts | length) > 0 and
          all(.parts[]; .encoding == "identity" and (.mirrorUrl | startswith($prefix)))
        )
      )' "${manifest_file}" >/dev/null
}

part_metadata_matches() {
  local mirror_url="$1"
  local expected_size="$2"
  local expected_sha="$3"
  local object_key head_json head_size head_sha
  [[ "${mirror_url}" == "${public_prefix}"* ]] || return 1
  object_key="${mirror_url#"${public_prefix}"}"
  [[ -n "${object_key}" && "${object_key}" != "${mirror_url}" ]] || return 1
  head_json="$(aws s3api head-object \
    --bucket "${R2_BUCKET}" --key "${object_key}" \
    --endpoint-url "${R2_ENDPOINT}" --region auto --output json 2>/dev/null)" || return 1
  head_size="$(jq -r '.ContentLength // 0' <<<"${head_json}")"
  head_sha="$(jq -r '.Metadata.sha256 // empty' <<<"${head_json}" | tr '[:upper:]' '[:lower:]')"
  [[ "${head_size}" == "${expected_size}" && "${head_sha}" == "${expected_sha}" ]]
}

versioned_manifest="${work}/versioned-current.json"
versioned_manifest_available=false
if curl -fsSL --connect-timeout 20 --max-time 60 --retry 2 --retry-all-errors \
  -H 'Cache-Control: no-cache' \
  -o "${versioned_manifest}" "${versioned_latest_url}"; then
  if ! manifest_matches_assets "${versioned_manifest}"; then
    echo "::error::Refusing to overwrite an immutable R2 version prefix with different bytes"
    exit 1
  fi
  versioned_manifest_available=true
fi

current_manifest="${work}/current.json"
if curl -fsSL --connect-timeout 20 --max-time 60 --retry 2 --retry-all-errors \
  -H 'Cache-Control: no-cache' \
  -o "${current_manifest}" "${latest_url}"; then
  if jq -e --arg tag "${MIRROR_TAG}" --arg version "${MIRROR_VERSION}" \
    '.tag == $tag and .version == $version' "${current_manifest}" >/dev/null 2>&1 \
    && ! manifest_matches_assets "${current_manifest}"; then
    echo "::error::Refusing to replace a stable pointer with different bytes for the same tag"
    exit 1
  fi
  if manifest_matches_assets "${current_manifest}"; then
    existing_parts="${work}/existing-parts.null"
    jq -r '.assets[].parts[] | [.mirrorUrl,.sizeBytes,.sha256] | @tsv' "${current_manifest}" |
      tr '\n' '\0' > "${existing_parts}"
    check_existing_part() {
      local row="$1" mirror_url expected_size expected_sha
      IFS=$'\t' read -r mirror_url expected_size expected_sha <<<"${row}"
      part_metadata_matches "${mirror_url}" "${expected_size}" "${expected_sha}"
    }
    export -f check_existing_part part_metadata_matches
    export public_prefix R2_BUCKET R2_ENDPOINT
    if xargs -0 -r -n 1 -P "${VERIFY_PARALLELISM}" \
      bash -c 'set -euo pipefail; check_existing_part "$1"' _ < "${existing_parts}"; then
      all_parts_present=true
    else
      all_parts_present=false
    fi
    if [[ "${versioned_manifest_available}" == true && "${all_parts_present}" == true ]]; then
      echo "R2 mirror already current: ${MIRROR_ID} ${MIRROR_TAG}"
      exit 0
    fi
  fi
fi

parts_dir="${work}/parts"
meta_dir="${work}/part-meta"
upload_queue="${work}/upload-queue.null"
mkdir -p "${parts_dir}" "${meta_dir}"
: > "${upload_queue}"
part_index=0
while IFS=$'\t' read -r filename path _ _ _; do
  asset_dir="${work}/split-${part_index}"
  mkdir -p "${asset_dir}"
  split -b "${RAW_PART_BYTES}" -d -a 4 "${path}" "${asset_dir}/raw-"
  for raw_part in "${asset_dir}"/raw-*; do
    suffix="${raw_part##*-}"
    part_name="${filename}.part-${suffix}"
    local_part="${parts_dir}/${part_name}"
    # split and parts_dir share the same mktemp filesystem; moving avoids a
    # second full-byte local copy before the upload workers read the part.
    mv -- "${raw_part}" "${local_part}"
    part_size="$(stat -c '%s' "${local_part}")"
    part_sha="$(sha256sum "${local_part}" | awk '{print tolower($1)}')"
    printf '%s\0%s\0%s\0' "${local_part}" "${part_size}" "${part_sha}" >> "${upload_queue}"
    object_key="${R2_PREFIX}/${part_name}"
    mirror_url="${R2_PUBLIC_BASE_URL}/${object_key}"
    jq -n \
      --arg assetFilename "${filename}" \
      --arg filename "${part_name}" \
      --arg mirrorUrl "${mirror_url}" \
      --arg sha256 "${part_sha}" \
      --argjson sizeBytes "${part_size}" \
      '{assetFilename:$assetFilename,filename:$filename,mirrorUrl:$mirrorUrl,sizeBytes:$sizeBytes,sha256:$sha256,encoding:"identity",decodedSizeBytes:$sizeBytes}' \
      > "${meta_dir}/$(printf '%05d' "${part_index}").json"
    part_index=$((part_index + 1))
  done
done < <(jq -r '.[] | [.filename,.path,.upstreamUrl,(.sizeBytes|tostring),.sha256] | @tsv' "${normalized_assets}")

upload_part() {
  local part expected_size expected_sha name object_key part_size head_json existing_path existing_size existing_sha
  part="$1"
  expected_size="$2"
  expected_sha="$3"
  name="${part##*/}"
  part_size="$(stat -c '%s' "${part}")"
  [[ "${part_size}" == "${expected_size}" ]]
  object_key="${R2_PREFIX}/${name}"
  if head_json="$(aws s3api head-object \
    --bucket "${R2_BUCKET}" --key "${object_key}" \
    --endpoint-url "${R2_ENDPOINT}" --region auto --output json 2>/dev/null)"; then
    if [[ "$(jq -r '.ContentLength // 0' <<<"${head_json}")" == "${expected_size}" \
      && "$(jq -r '.Metadata.sha256 // empty' <<<"${head_json}" | tr '[:upper:]' '[:lower:]')" == "${expected_sha}" ]]; then
      echo "R2 part already verified ${name}"
      return 0
    fi
    # Older R2 objects predate the metadata field. Re-read them before adding
    # metadata; a same-tag object with different bytes is never overwritten.
    existing_path="${work}/existing-${name}"
    curl -fsSL --connect-timeout 30 --max-time 900 --retry 3 --retry-all-errors \
      -o "${existing_path}" "${public_prefix}${object_key}"
    existing_size="$(stat -c '%s' "${existing_path}")"
    existing_sha="$(sha256sum "${existing_path}" | awk '{print tolower($1)}')"
    rm -f "${existing_path}"
    if [[ "${existing_size}" != "${expected_size}" || "${existing_sha}" != "${expected_sha}" ]]; then
      echo "::error::Immutable R2 part differs from the verified upstream bytes: ${name}"
      return 1
    fi
  fi
  echo "Uploading R2 ${name}"
  aws s3 cp "${part}" "s3://${R2_BUCKET}/${object_key}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --region auto \
    --content-type application/octet-stream \
    --metadata "sha256=${expected_sha}" \
    --cache-control 'public,max-age=31536000,immutable' \
    --only-show-errors
}
export -f upload_part
export work public_prefix R2_BUCKET R2_PREFIX R2_ENDPOINT
xargs -0 -r -n 3 -P "${UPLOAD_PARALLELISM}" \
  bash -c 'set -euo pipefail; upload_part "$1" "$2" "$3"' _ < "${upload_queue}"

verify_part() {
  local meta filename url expected_size expected_sha downloaded actual_size actual_sha
  meta="$1"
  filename="$(jq -r '.filename' "${meta}")"
  url="$(jq -r '.mirrorUrl' "${meta}")"
  expected_size="$(jq -r '.sizeBytes' "${meta}")"
  expected_sha="$(jq -r '.sha256' "${meta}")"
  downloaded="${verify_dir}/${filename}"
  curl -fsSL --connect-timeout 30 --max-time 900 --retry 4 --retry-all-errors \
    --retry-delay 3 -o "${downloaded}" "${url}"
  actual_size="$(stat -c '%s' "${downloaded}")"
  actual_sha="$(sha256sum "${downloaded}" | awk '{print tolower($1)}')"
  [[ "${actual_size}" == "${expected_size}" ]]
  [[ "${actual_sha}" == "${expected_sha}" ]]
  rm -f "${downloaded}"
  echo "Verified R2 ${filename}"
}
verify_dir="${work}/verified"
mkdir -p "${verify_dir}"
export -f verify_part
export verify_dir
find "${meta_dir}" -maxdepth 1 -type f -name '*.json' -print0 | \
  xargs -0 -n 1 -P "${VERIFY_PARALLELISM}" bash -c 'set -euo pipefail; verify_part "$1"' _

manifest_assets='[]'
while IFS=$'\t' read -r filename _ upstream_url size_bytes sha256; do
  parts="$(jq -s --arg filename "${filename}" \
    'map(select(.assetFilename == $filename) | del(.assetFilename)) | sort_by(.filename)' \
    "${meta_dir}"/*.json)"
  [[ "$(jq 'length' <<<"${parts}")" -gt 0 ]]
  asset="$(jq -n \
    --arg filename "${filename}" \
    --arg upstreamUrl "${upstream_url}" \
    --arg sha256 "${sha256}" \
    --argjson sizeBytes "${size_bytes}" \
    --argjson parts "${parts}" \
    '{filename:$filename,upstreamUrl:$upstreamUrl,sizeBytes:$sizeBytes,sha256:$sha256,parts:$parts}')"
  manifest_assets="$(jq -c --argjson asset "${asset}" '. + [$asset]' <<<"${manifest_assets}")"
done < <(jq -r '.[] | [.filename,.path,.upstreamUrl,(.sizeBytes|tostring),.sha256] | @tsv' "${normalized_assets}")

manifest="${work}/latest.json"
jq -n \
  --arg upstreamRepository "${UPSTREAM_REPOSITORY}" \
  --arg tag "${MIRROR_TAG}" \
  --arg version "${MIRROR_VERSION}" \
  --arg upstreamReleaseUrl "${UPSTREAM_RELEASE_URL}" \
  --arg mirrorRepository "${MIRROR_REPOSITORY}" \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson assets "${manifest_assets}" \
  '{schemaVersion:3,mirrorProvider:"cloudflare_r2",upstreamRepository:$upstreamRepository,tag:$tag,version:$version,upstreamReleaseUrl:$upstreamReleaseUrl,mirrorRepository:$mirrorRepository,generatedAt:$generatedAt,assets:$assets}' \
  > "${manifest}"

aws s3 cp "${manifest}" "s3://${R2_BUCKET}/${R2_PREFIX}/latest.json" \
  --endpoint-url "${R2_ENDPOINT}" --region auto \
  --content-type application/json --cache-control 'no-cache' --only-show-errors

# Keep the immutable versioned manifest for auditability, then atomically
# replace the stable pointer only after every part and the versioned object
# have been uploaded. A failed pointer upload leaves the previous release
# discoverable instead of exposing a partial release.
aws s3 cp "${manifest}" "s3://${R2_BUCKET}/${R2_LATEST_KEY}" \
  --endpoint-url "${R2_ENDPOINT}" --region auto \
  --content-type application/json --cache-control 'no-cache' --only-show-errors

expected_manifest_sha="$(sha256sum "${manifest}" | awk '{print tolower($1)}')"
published_manifest="${work}/published-latest.json"
for attempt in $(seq 1 30); do
  if curl -fsSL --connect-timeout 20 --max-time 60 --retry 1 --retry-all-errors \
    -H 'Cache-Control: no-cache' \
    -o "${published_manifest}" "${latest_url}"; then
    published_sha="$(sha256sum "${published_manifest}" | awk '{print tolower($1)}')"
    [[ "${published_sha}" == "${expected_manifest_sha}" ]] && break
  fi
  sleep 5
done
[[ -f "${published_manifest}" ]]
[[ "$(sha256sum "${published_manifest}" | awk '{print tolower($1)}')" == "${expected_manifest_sha}" ]]
echo "Published verified R2 mirror ${MIRROR_ID} ${MIRROR_TAG} with ${part_index} raw parts"
