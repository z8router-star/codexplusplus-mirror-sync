#!/usr/bin/env bash
set -euo pipefail

: "${R2_ACCOUNT_ID:?Set the CLOUDFLARE_ACCOUNT_ID repository variable}"
: "${R2_ACCESS_KEY_ID:?Set the R2_ACCESS_KEY_ID repository secret}"
: "${R2_SECRET_ACCESS_KEY:?Set the R2_SECRET_ACCESS_KEY repository secret}"
: "${R2_BUCKET:?Set the R2_BUCKET repository variable}"
: "${R2_PUBLIC_BASE_URL:?Set the R2_PUBLIC_BASE_URL repository variable}"
: "${GITEE_TOKEN:?Set the GITEE_TOKEN repository secret}"
: "${GITEE_OWNER:?Set GITEE_OWNER}"
: "${GITEE_REPO:?Set GITEE_REPO}"
: "${UPSTREAM_REPOSITORY:?Set UPSTREAM_REPOSITORY}"
: "${UPSTREAM_RELEASE_URL:?Set UPSTREAM_RELEASE_URL}"
: "${MIRROR_TAG:?Set MIRROR_TAG}"
: "${MIRROR_VERSION:?Set MIRROR_VERSION}"
: "${ASSET_SPEC_FILE:?Set ASSET_SPEC_FILE}"

RAW_PART_BYTES="${RAW_PART_BYTES:-50331648}"
UPLOAD_PARALLELISM="${UPLOAD_PARALLELISM:-8}"
VERIFY_PARALLELISM="${VERIFY_PARALLELISM:-8}"
R2_PUBLIC_BASE_URL="${R2_PUBLIC_BASE_URL%/}"
R2_PREFIX="${R2_PREFIX:-z8-launch/${GITEE_REPO}/${MIRROR_TAG}}"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
GITEE_API="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}"
GITEE_AUTH="Authorization: token ${GITEE_TOKEN}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

[[ "${R2_ACCOUNT_ID}" =~ ^[A-Fa-f0-9]{32}$ ]]
[[ "${R2_BUCKET}" =~ ^[A-Za-z0-9._-]{1,63}$ ]]
[[ "${R2_PUBLIC_BASE_URL}" =~ ^https://[^/?#]+(/[^/?#]+)*$ ]]
[[ "${R2_PREFIX}" =~ ^[A-Za-z0-9._/-]+$ ]]
[[ "${MIRROR_TAG}" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "${MIRROR_VERSION}" =~ ^[A-Za-z0-9._-]+$ ]]
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

latest_url="https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/raw/master/latest.json"
current_manifest="${work}/current.json"
if curl -fsSL --connect-timeout 20 --max-time 60 --retry 2 --retry-all-errors \
  -o "${current_manifest}" "${latest_url}"; then
  if jq -e \
    --arg repository "${GITEE_OWNER}/${GITEE_REPO}" \
    --arg tag "${MIRROR_TAG}" \
    --arg version "${MIRROR_VERSION}" \
    --arg base "${R2_PUBLIC_BASE_URL}/" \
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
          all(.parts[]; .encoding == "identity" and (.mirrorUrl | startswith($base)))
        )
      )' "${current_manifest}" >/dev/null; then
    all_parts_present=true
    public_prefix="${R2_PUBLIC_BASE_URL}/"
    while IFS= read -r mirror_url; do
      object_key="${mirror_url#"${public_prefix}"}"
      if [[ "${object_key}" == "${mirror_url}" ]] || ! aws s3api head-object \
        --bucket "${R2_BUCKET}" --key "${object_key}" \
        --endpoint-url "${R2_ENDPOINT}" --region auto >/dev/null 2>&1; then
        all_parts_present=false
        break
      fi
    done < <(jq -r '.assets[].parts[].mirrorUrl' "${current_manifest}")
    if [[ "${all_parts_present}" == true ]]; then
      echo "R2 mirror already current: ${GITEE_OWNER}/${GITEE_REPO} ${MIRROR_TAG}"
      exit 0
    fi
  fi
fi

parts_dir="${work}/parts"
meta_dir="${work}/part-meta"
mkdir -p "${parts_dir}" "${meta_dir}"
part_index=0
while IFS=$'\t' read -r filename path _ _ _; do
  asset_dir="${work}/split-${part_index}"
  mkdir -p "${asset_dir}"
  split -b "${RAW_PART_BYTES}" -d -a 4 "${path}" "${asset_dir}/raw-"
  for raw_part in "${asset_dir}"/raw-*; do
    suffix="${raw_part##*-}"
    part_name="${filename}.part-${suffix}"
    local_part="${parts_dir}/${part_name}"
    cp "${raw_part}" "${local_part}"
    part_size="$(stat -c '%s' "${local_part}")"
    part_sha="$(sha256sum "${local_part}" | awk '{print tolower($1)}')"
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
  local part name object_key
  part="$1"
  name="${part##*/}"
  object_key="${R2_PREFIX}/${name}"
  echo "Uploading R2 ${name}"
  aws s3 cp "${part}" "s3://${R2_BUCKET}/${object_key}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --region auto \
    --content-type application/octet-stream \
    --cache-control 'public,max-age=31536000,immutable' \
    --only-show-errors
}
export -f upload_part
export R2_BUCKET R2_PREFIX R2_ENDPOINT
find "${parts_dir}" -maxdepth 1 -type f -print0 | \
  xargs -0 -n 1 -P "${UPLOAD_PARALLELISM}" bash -c 'upload_part "$1"' _

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
  xargs -0 -n 1 -P "${VERIFY_PARALLELISM}" bash -c 'verify_part "$1"' _

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
  --arg mirrorRepository "${GITEE_OWNER}/${GITEE_REPO}" \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson assets "${manifest_assets}" \
  '{schemaVersion:3,mirrorProvider:"cloudflare_r2",upstreamRepository:$upstreamRepository,tag:$tag,version:$version,upstreamReleaseUrl:$upstreamReleaseUrl,mirrorRepository:$mirrorRepository,generatedAt:$generatedAt,assets:$assets}' \
  > "${manifest}"

aws s3 cp "${manifest}" "s3://${R2_BUCKET}/${R2_PREFIX}/latest.json" \
  --endpoint-url "${R2_ENDPOINT}" --region auto \
  --content-type application/json --cache-control 'no-cache' --only-show-errors

ensure_master_branch() {
  local status payload
  status="$(curl -sS -o /dev/null -w '%{http_code}' -H "${GITEE_AUTH}" "${GITEE_API}/branches/master")"
  [[ "${status}" == '200' ]] && return 0
  [[ "${status}" == '404' ]]
  payload="$(jq -n --arg message 'initialize Z8 Launch mirror' --arg content 'WjggTGF1bmNoIG1pcnJvciBib290c3RyYXAuCg==' --arg branch master '{message:$message,content:$content,branch:$branch}')"
  curl -fsSL --retry 3 --retry-all-errors -X POST -H "${GITEE_AUTH}" \
    -H 'Content-Type: application/json' -d "${payload}" \
    "${GITEE_API}/contents/.z8-launch-mirror" >/dev/null
}

ensure_master_branch
content="$(base64 -w0 "${manifest}")"
contents_response="${work}/contents.json"
contents_status="$(curl -sS -o "${contents_response}" -w '%{http_code}' -H "${GITEE_AUTH}" \
  "${GITEE_API}/contents/latest.json?ref=master")"
sha=''
[[ "${contents_status}" == '200' ]] && sha="$(jq -r '.sha // empty' "${contents_response}")"
payload="$(jq -n --arg message "sync R2 latest ${MIRROR_VERSION}" --arg content "${content}" --arg branch master --arg sha "${sha}" 'if $sha == "" then {message:$message,content:$content,branch:$branch} else {message:$message,content:$content,branch:$branch,sha:$sha} end')"
method='POST'
[[ -n "${sha}" ]] && method='PUT'
update_status="$(curl -sS -o "${contents_response}" -w '%{http_code}' --retry 3 --retry-all-errors \
  -X "${method}" -H "${GITEE_AUTH}" -H 'Content-Type: application/json' \
  -d "${payload}" "${GITEE_API}/contents/latest.json")"
[[ "${update_status}" =~ ^2[0-9][0-9]$ ]]

expected_manifest_sha="$(sha256sum "${manifest}" | awk '{print tolower($1)}')"
published_manifest="${work}/published-latest.json"
for attempt in $(seq 1 30); do
  if curl -fsSL --connect-timeout 20 --max-time 60 --retry 1 --retry-all-errors \
    -o "${published_manifest}" "${latest_url}"; then
    published_sha="$(sha256sum "${published_manifest}" | awk '{print tolower($1)}')"
    [[ "${published_sha}" == "${expected_manifest_sha}" ]] && break
  fi
  sleep 5
done
[[ -f "${published_manifest}" ]]
[[ "$(sha256sum "${published_manifest}" | awk '{print tolower($1)}')" == "${expected_manifest_sha}" ]]
echo "Published verified R2 mirror ${GITEE_OWNER}/${GITEE_REPO} ${MIRROR_TAG} with ${part_index} raw parts"
