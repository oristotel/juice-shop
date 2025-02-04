#!/bin/bash

set -e

report_file="$1"
target_host="$2"
project="${JIRA_PROJECT}"
ignore_ids="${IGNORE_IDS:-2 10026}"

# If ignore_ids is actually a file instead of numbers
if [ -f "${ignore_ids}" ]
then
  # https://github.com/zaproxy/zaproxy/wiki/ZAP-Baseline-Scan#configuration-file
  echo "[i] Reading alerts conf file for alerts to ignore"
  ignore_ids="$(cat ${ignore_ids}  | grep -v '^#' | grep IGNORE | awk '{ print $1 }' | tr '\r\n' ' ')"
fi

if [ -z "${target_host}" ]
then
  echo '[!] You need to provide a target host ./zap_alerts_to_jira.sh report.json myapp.com'
  exit 10
fi

should_ignore_id()
{
  local id="$1"
  if [ -z "$ignore_ids" ]
  then
    return 1
  fi

  for iid in ${ignore_ids}
  do
    if [ "$iid" == "$id" ]
    then
      return 0
    fi
  done
  return 1
}

create_jira_issue() 
{
  local summary="$1"
  local alert="$2"
  description=$(echo "${alert}" | jq -r '.description,"\n", (.uris[] | " - \(.)")' | sed "s/://g")
  
  # If you want to add custom fields etc, you will need to change the go-jira create templates
  # which can be generated with `jira export-templates` and then
  # adjusted in ~/.jira.d/templates/create
  jira create --project="${project}" \
    --issuetype=Task \
    --noedit \
    --override="summary=${summary}" \
    --override="description=${description}"
}

handle_target_alerts()
{
  local target="$1"
  local alerts="$2"
  while read -r alert
  do
    id=$(echo "${alert}" | jq -r '.id')
    prefix=$(echo "${alert}" | jq -r '"\(.id) -- \(.name)"')

    if should_ignore_id "$id"
    then
      echo "[i] Ignoring alert $prefix"
      continue
    fi

    risk_code=$(echo "${alert}" | jq -r '.riskcode')

    if [ "$risk_code" == "0" ]
    then
      echo "[i] Low risk ... skipping creating [${prefix}]"
      continue
    fi

    # If you change your summary after issues have been created, you will end up with duplicates
    summary="${prefix} -- ${target}"
    found=$(jira list --limit=1 --query "project=${project} AND summary~'\"${summary}\"'")

    if [ "${found}" == "" ]
    then
      create_jira_issue "${summary}" "${alert}"
    else
      issue_key=$(echo "${found}" | cut -d':' -f1)
      echo "[i] Issue already being tracked ${issue_key} [${prefix}]"
      jira comment "${issue_key}" --noedit  --comment='ZAP issue still being seen'
    fi
  done<<< "${alerts}"
}

if !(command -v jira) || !(command -v jq)
then
  echo "[!] Expects jira cli & jq to be installed"
  echo " - https://github.com/Netflix-Skunkworks/go-jira"
  exit 1
fi

if [ ! -f "${report_file}" ]
then
  echo "[!] That does not appear to be a report file ${report_file}"
  exit 1
fi

if [ -z "${project}" ]
then
  echo '[!] Specify your jira project with JIRA_PROJECT env variable'
  exit 1
fi

echo '[i] Checking if the configured JIRA project exists'

if !(jira list --project="${project}" --limit=1)
then
  echo "[!] That project does not exist"
  exit 1
fi

site_type=$(cat "${report_file}" | jq -r '.site | type')
if [ "$site_type" == "array" ]
then
  max=$(cat "${report_file}" | jq -r '.site | length')
  max=$((max-1))
  for i in $(seq 0 $max)
  do
    target=$(cat "${report_file}" | jq -r ".site[$i][\"@host\"]")

    if [ "${target}" != "${target_host}" ]
    then
      echo "[!] Ignoring alerts for ${target}" 
      continue
    fi

    alerts=$(cat "${report_file}" | jq -r -c -a -M ".site[$i].alerts[] | {uris: [.instances[]|.uri], description: .desc, id: .pluginid, name: .alert, riskcode: .riskcode }" | xargs -L1 -0)
    handle_target_alerts "${target}" "${alerts}"
  done
else 
  target=$(cat "${report_file}" | jq -r '.site["@host"]')

  if [ "${target}" != "${target_host}" ]
  then
    echo "[!] Ignoring alerts for ${target}"
    return
  fi
    
  alerts=$(cat "${report_file}" | jq -r -c -a -M '.site.alerts[] | {uris: [.instances[]|.uri], description: .desc, id: .pluginid, name: .alert, riskcode: .riskcode }' | xargs -L1 -0)
  handle_target_alerts "${target}" "${alerts}"
fi