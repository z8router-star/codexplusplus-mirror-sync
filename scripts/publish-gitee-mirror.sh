#!/usr/bin/env bash
set -euo pipefail

: "${GITEE_TOKEN:?Set the GITEE_TOKEN repository secret first}"
: "${GITEE_OWNER:?Set GITEE_OWNER}"
: "${GITEE_REPO:?Set GITEE_REPO}"
: "${UPSTREAM_REPOSITORY:?Set UPSTREAM_REPOSITORY}"
: "${UPSTREAM_RELEASE_URL:?Set UPSTREAM_RELEASE_URL}"
: "${MIRROR_TAG:?Set MIRROR_TAG}"
: "${MIRROR_VERSION:?Set MIRROR_VERSION}"
: "${ASSET_SPEC_FILE:?Set ASSET_SPEC_FILE}"

RAW_PART_BYTES="${RAW_PART_BYTES:-8388608}"
UPLOAD_PARALLELISM="${UPLOAD_PARALLELISM:-4}"
VERIFY_PARALLELISM="${VERIFY_PARALLELISM:-4}"
api="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}"
auth="Authorization: token ${GITEE_TOKEN}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

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
    --slurpfile expected "${normalized_assets}" '
      . as $manifest |
      .schemaVersion == 3 and
      .mirrorRepository == $repository and
      .tag == $tag and
      .version == $version and
      (.assets | length) == ($expected[0] | length) and
      all($expected[0][];
        . as $asset |
        any($manifest.assets[];
          .filename == $asset.filename and
          .sizeBytes == $asset.sizeBytes and
          (.sha256 | ascii_downcase) == $asset.sha256 and
          (.parts | length) > 0 and
          all(.parts[]; .encoding == "base64" and .decodedSizeBytes > 0)
        )
      )' "${current_manifest}" >/dev/null; then
    echo "Mirror already current: ${GITEE_OWNER}/${GITEE_REPO} ${MIRROR_TAG}"
    exit 0
  fi
fi

ensure_master_branch() {
  local status payload
  status="$(curl -sS -o /dev/null -w '%{http_code}' -H "${auth}" "${api}/branches/master")"
  [[ "${status}" == '200' ]] && return 0
  [[ "${status}" == '404' ]]
  payload="$(jq -n \
    --arg message 'initialize Z8 Launch mirror' \
    --arg content 'WjggTGF1bmNoIG1pcnJvciBib290c3RyYXAuCg==' \
    --arg branch master \
    '{message:$message,content:$content,branch:$branch}')"
  curl -fsSL --retry 3 --retry-all-errors -X POST \
    -H "${auth}" -H 'Content-Type: application/json' -d "${payload}" \
    "${api}/contents/.z8-launch-mirror" >/dev/null
}

ensure_release() {
  local release_json status releases_json list_status tag_json tag_status tag_payload payload
  release_json="${work}/release.json"
  status="$(curl -sS -o "${release_json}" -w '%{http_code}' -H "${auth}" \
    "${api}/releases/tags/${MIRROR_TAG}")"
  if [[ "${status}" == '200' && "$(jq -r 'type' "${release_json}")" == 'null' ]]; then
    releases_json="${work}/releases.json"
    list_status="$(curl -sS -o "${releases_json}" -w '%{http_code}' -H "${auth}" \
      "${api}/releases?per_page=100")"
    if [[ "${list_status}" =~ ^2[0-9][0-9]$ ]]; then
      jq --arg tag "${MIRROR_TAG}" 'map(select(.tag_name == $tag)) | first // null' \
        "${releases_json}" > "${release_json}"
    fi
    [[ "$(jq -r 'type' "${release_json}")" != 'null' ]] || status='404'
  fi
  if [[ "${status}" == '404' ]]; then
    tag_json="${work}/tag.json"
    tag_status="$(curl -sS -o "${tag_json}" -w '%{http_code}' -H "${auth}" \
      "${api}/tags/${MIRROR_TAG}")"
    if [[ "${tag_status}" == '404' ]]; then
      tag_payload="$(jq -n --arg tag "${MIRROR_TAG}" '{tag_name:$tag,refs:"master"}')"
      tag_status="$(curl -sS -o "${tag_json}" -w '%{http_code}' \
        --retry 3 --retry-all-errors -X POST -H "${auth}" \
        -H 'Content-Type: application/json' -d "${tag_payload}" "${api}/tags")"
    fi
    [[ "${tag_status}" =~ ^2[0-9][0-9]$ ]] || {
      echo "::error::Unable to ensure Gitee tag ${MIRROR_TAG} (HTTP ${tag_status})"
      return 1
    }
    payload="$(jq -n \
      --arg tag "${MIRROR_TAG}" \
      --arg name "${UPSTREAM_REPOSITORY} ${MIRROR_VERSION}" \
      --arg body "Verified mirror of ${UPSTREAM_RELEASE_URL}. Z8 Launch validates every Base64 part, reconstructed SHA-256, and platform signature policy." \
      '{tag_name:$tag,name:$name,body:$body,target_commitish:"master",prerelease:false}')"
    status="$(curl -sS -o "${release_json}" -w '%{http_code}' \
      --retry 3 --retry-all-errors -X POST -H "${auth}" \
      -H 'Content-Type: application/json' -d "${payload}" "${api}/releases")"
  fi
  [[ "${status}" =~ ^2[0-9][0-9]$ ]] || {
    echo "::error::Unable to ensure Gitee release ${MIRROR_TAG} (HTTP ${status})"
    return 1
  }
  release_id="$(jq -r '.id // .release.id // .data.id // empty' "${release_json}")"
  [[ "${release_id}" =~ ^[0-9]+$ ]] || {
    echo '::error::Gitee release response did not contain a numeric id'
    return 1
  }
  export release_id
}

ensure_master_branch
ensure_release

existing_json="${work}/existing-assets.json"
curl -fsSL --retry 3 --retry-all-errors -H "${auth}" \
  "${api}/releases/${release_id}/attach_files?per_page=100" > "${existing_json}"
while IFS=$'\t' read -r attachment_id attachment_name; do
  [[ "${attachment_id}" =~ ^[0-9]+$ ]] || continue
  echo "Removing stale attachment ${attachment_name}"
  curl -fsSL --retry 3 --retry-all-errors -X DELETE -H "${auth}" \
    "${api}/releases/${release_id}/attach_files/${attachment_id}" >/dev/null
done < <(jq -r '.[]? | [.id,.name] | @tsv' "${existing_json}")

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
    part_name="${filename}.part-${suffix}.b64"
    encoded_part="${parts_dir}/${part_name}"
    base64 -w0 "${raw_part}" > "${encoded_part}"
    encoded_size="$(stat -c '%s' "${encoded_part}")"
    decoded_size="$(stat -c '%s' "${raw_part}")"
    encoded_sha="$(sha256sum "${encoded_part}" | awk '{print tolower($1)}')"
    jq -n \
      --arg assetFilename "${filename}" \
      --arg filename "${part_name}" \
      --arg mirrorUrl "https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/releases/download/${MIRROR_TAG}/${part_name}" \
      --arg sha256 "${encoded_sha}" \
      --argjson sizeBytes "${encoded_size}" \
      --argjson decodedSizeBytes "${decoded_size}" \
      '{assetFilename:$assetFilename,filename:$filename,mirrorUrl:$mirrorUrl,sizeBytes:$sizeBytes,sha256:$sha256,encoding:"base64",decodedSizeBytes:$decodedSizeBytes}' \
      > "${meta_dir}/$(printf '%05d' "${part_index}").json"
    part_index=$((part_index + 1))
  done
done < <(jq -r '.[] | [.filename,.path,.upstreamUrl,(.sizeBytes|tostring),.sha256] | @tsv' "${normalized_assets}")

upload_part() {
  local part upload_json status name
  part="$1"
  name="${part##*/}"
  upload_json="${part}.upload.json"
  echo "Uploading ${name}"
  status="$(curl -sS -o "${upload_json}" -w '%{http_code}' \
    --connect-timeout 30 --max-time 900 --retry 2 --retry-all-errors --retry-delay 5 \
    -X POST -H "${auth}" -H 'Expect:' \
    -F "file=@${part};filename=${name}" \
    "${api}/releases/${release_id}/attach_files")" || true
  if [[ ! "${status}" =~ ^2[0-9][0-9]$ ]]; then
    echo "::error::Gitee upload failed for ${name} (HTTP ${status})"
    jq -c '{message:.message,error:.error,errors:.errors}' "${upload_json}" 2>/dev/null || true
    return 1
  fi
}
export -f upload_part
export api auth
find "${parts_dir}" -maxdepth 1 -type f -name '*.b64' -print0 | \
  xargs -0 -n 1 -P "${UPLOAD_PARALLELISM}" bash -c 'upload_part "$1"' _

verify_part() {
  local meta filename url expected_size expected_sha downloaded attempt actual_size actual_sha
  meta="$1"
  filename="$(jq -r '.filename' "${meta}")"
  url="$(jq -r '.mirrorUrl' "${meta}")"
  expected_size="$(jq -r '.sizeBytes' "${meta}")"
  expected_sha="$(jq -r '.sha256' "${meta}")"
  downloaded="${verify_dir}/${filename}"
  for attempt in $(seq 1 30); do
    if curl -fsSL --connect-timeout 30 --max-time 600 --retry 2 --retry-all-errors \
      --retry-delay 5 -o "${downloaded}" "${url}"; then
      actual_size="$(stat -c '%s' "${downloaded}")"
      actual_sha="$(sha256sum "${downloaded}" | awk '{print tolower($1)}')"
      if [[ "${actual_size}" == "${expected_size}" && "${actual_sha}" == "${expected_sha}" ]]; then
        echo "Verified ${filename}"
        rm -f "${downloaded}"
        return 0
      fi
    fi
    rm -f "${downloaded}"
    sleep 10
  done
  echo "::error::Gitee attachment verification failed for ${filename}"
  return 1
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
  '{schemaVersion:3,upstreamRepository:$upstreamRepository,tag:$tag,version:$version,upstreamReleaseUrl:$upstreamReleaseUrl,mirrorRepository:$mirrorRepository,generatedAt:$generatedAt,assets:$assets}' \
  > "${manifest}"

content="$(base64 -w0 "${manifest}")"
contents_response="${work}/contents.json"
contents_status="$(curl -sS -o "${contents_response}" -w '%{http_code}' -H "${auth}" \
  "${api}/contents/latest.json?ref=master")"
sha=''
[[ "${contents_status}" == '200' ]] && sha="$(jq -r '.sha // empty' "${contents_response}")"
payload="$(jq -n \
  --arg message "sync latest ${MIRROR_VERSION}" \
  --arg content "${content}" \
  --arg branch master \
  --arg sha "${sha}" \
  'if $sha == "" then {message:$message,content:$content,branch:$branch} else {message:$message,content:$content,branch:$branch,sha:$sha} end')"
method='POST'
[[ -n "${sha}" ]] && method='PUT'
update_status="$(curl -sS -o "${contents_response}" -w '%{http_code}' \
  --retry 3 --retry-all-errors -X "${method}" -H "${auth}" \
  -H 'Content-Type: application/json' -d "${payload}" "${api}/contents/latest.json")"
[[ "${update_status}" =~ ^2[0-9][0-9]$ ]] || {
  echo "::error::Gitee latest.json update failed (HTTP ${update_status})"
  exit 1
}

expected_manifest_sha="$(sha256sum "${manifest}" | awk '{print tolower($1)}')"
published_manifest="${work}/published-latest.json"
for attempt in $(seq 1 30); do
  if curl -fsSL --connect-timeout 20 --max-time 60 --retry 1 --retry-all-errors \
    -o "${published_manifest}" "${latest_url}"; then
    published_sha="$(sha256sum "${published_manifest}" | awk '{print tolower($1)}')"
    [[ "${published_sha}" == "${expected_manifest_sha}" ]] && break
  fi
  sleep 10
done
[[ -f "${published_manifest}" ]]
[[ "$(sha256sum "${published_manifest}" | awk '{print tolower($1)}')" == "${expected_manifest_sha}" ]]
echo "Published verified mirror ${GITEE_OWNER}/${GITEE_REPO} ${MIRROR_TAG} with ${part_index} parts"
