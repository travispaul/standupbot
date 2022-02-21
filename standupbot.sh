#!/bin/sh

# This is my personal script for generating my daily standup post in Slack.
# Its highly tailored for my use case and is likely better off as an example
# for starting your own rather than, using this as-is. I'm sharing it because
# it was fun to make and I wrote about it here: 
#   https://travispaul.me/thoughts/2022/02/automating_daily_standups/
#
# This script is NOT an attempt to "game the system", in fact I run it manually
# and make sure the info is accurate.
# I also check in on what other people are working on too (that's part of a good
# standup), so its not passive at all, and mostly for a bit of useful fun.
#
# Fair warning:
#  This script plays it "fast and loose" in regards to JSON serialization.
#  It has yet to break but it is probably a matter of time before quotes
#  are encountered in a JIRA story or track name and prevent it from posting.
#
# Required environment variables:
#
# JIRA_TOKEN
# JIRA_USERID
# JIRA_CLOUDID
#
# LASTFM_KEY
# LASTFM_USER
#
# SLACK_WEBHOOK
# SLACK_CHANNEL
# SLACK_EMOJI
# SLACK_USER
#
# GITHUB_USER
# GITHUB_ORG
#
# Required executables:
#  curl
#  jq
#
# Example usage:
#   ./standupbot.sh
#
#  to test output without sending to Slack:
#    ./standupbot.sh test

get_worklog() {
  curl -s --request POST \
    --url "https://atlassian.net/gateway/api/graphql" \
    --header "Content-Type: application/json" \
    --user "$JIRA_USER:$JIRA_TOKEN" \
    --data @graphql.json | jq -c '.data.activities.workedOn.nodes[]'
}

get_in_flight() {
  curl -s --request POST \
    --url "https://$JIRA_HOST/rest/api/2/search" \
    --header "Content-Type: application/json" \
    --user "$JIRA_USER:$JIRA_TOKEN" \
    --data @jql.json | jq -c '.issues[]'
}

get_github_activity() {
  curl -s -u "$GITHUB_USER:$GITHUB_ACCESS_TOKEN" \
    https://api.github.com/users/$GITHUB_USER/events/orgs/$GITHUB_ORG \
    | jq -c '.[]'
}

get_reviews() {
  for i in $(get_github_activity); do
    local type="$(echo "$i" | jq -r .type)"
    local repo="$(echo "$i" | jq -r .repo.name)"
    local created="$(echo "$i" | jq -r .created_at)"
    local user="$(echo "$i" | jq -r .actor.login)"

    local event=
    if $(echo $created | grep -q "$yesterday") && [ "$user" = "$GITHUB_USER" ]; then
      case $type in
        PullRequestReviewEvent) echo "PR review for $repo";;
        PushEvent) echo "Pushed to $repo";;
        *) echo "$type for $repo";;
      esac
    fi
  done
}

get_playing() {
  local track="$(curl -s "http://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=$LASTFM_USER&api_key=$LASTFM_KEY&limit=1&format=json" | jq '.recenttracks.track[0]')"
  local url=$(echo "$track" | jq -r '.url')
  local artist=$(echo "$track" | jq -r '.artist["#text"]')
  local name=$(echo "$track" | jq -r '.name')
  echo "<$url|$name by $artist>"
}

send_slack() {
  local message="$1"
  local payload="payload={\"channel\":\"$SLACK_CHANNEL\",\"username\":\"$SLACK_USER\",\"text\":\"$message\",\"icon_emoji\":\"$SLACK_EMOJI\"}"
  curl -s -X POST --data-urlencode "$payload" "$SLACK_WEBHOOK"
}

cleanup () {
  exitcode=${1:-1}
  rm {graphql,jql}.json
  exit $exitcode
}

render_templates() {
  for i in graphql jql; do
    sed -e "s/__CLOUD_ID__/$JIRA_CLOUDID/g" \
      -e "s/__USER_ID__/$JIRA_USERID/g" "$i.json.in" > "$i.json"
  done
}

trap cleanup ERR

render_templates

if [ "$(date '+%A')" = "Monday" ]; then
  yesterday=$(date -d '3 days ago' '+%F')
else
  yesterday=$(date -d 'yesterday' '+%F')
fi

if [ "$(date '+%A')" = "Monday" ]; then
  message="*Friday:*\n"
else
  message="*Yesterday:*\n"
fi

IFS="
"

for i in $(get_worklog); do
  timestamp=$(echo "$i" | jq .timestamp)
  if $(echo $timestamp | grep -q "$yesterday"); then
    product=$(echo "$i" | jq -r .object.product)
    name=$(echo "$i" | jq -r .object.name)
    id=$(echo "$i" | jq -r .object.extension.issueKey)

    events=
    for j in $(echo "$i" | jq -c .object.events[]); do
      e="$(echo "$j" | jq -r .eventType)"
      case $e in
        COMMENTED) e="Commented on";;
        PUBLISHED) e="Published";;
        UPDATED) e="Updated Story";;
        *) e=$(echo $e |  tr '[:upper:]' '[:lower:]')
      esac
      if [ ! -z $events ]; then
        events="$events and $e"
      else
        events="$e"
      fi
    done

    if [ "$product" == "CONFLUENCE" ]; then
      message="$message :confluence: $events '$name' Confluence page\n"
    else
      message="$message:jira: $events '$(echo $id - $name | xargs)'\n"
    fi
  fi
done

for i in $(get_reviews | sort -u); do
  message="${message}:github: $i\n"
done

message="${message}\n*Today*:\n"

for i in $(get_in_flight); do
    summary=$(echo "$i" | jq -r .fields.summary | xargs)
    id=$(echo "$i" | jq -r .key)
    message="$message:jira: $id - $summary\n"
done

playing_now="\n:lastfm: *Currently Playing:* $(get_playing)"

message="${message}${playing_now}\n"

if [ "$1" != "test" ]; then
  send_slack "$message"
else
  echo -e "$message"
fi

cleanup 0
