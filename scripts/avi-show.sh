#!/usr/bin/env bash
# Print the Avi objects AKO built for the rollouts-demo HTTPRoute: virtual
# services, pool group ratios, and each pool's servers. Read-only GETs.
# Needs AVI_PASSWORD. AVI_HOST, AVI_USER, AVI_TENANT, ROUTE_NS, ROUTE override defaults.
set -euo pipefail
AVI=https://${AVI_HOST:?set AVI_HOST}
AVI_USER=${AVI_USER:-admin}
TENANT=${AVI_TENANT:-admin}         # AKO tenantName (avi-k8s-config)
ROUTE_NS=${ROUTE_NS:-rollouts-demo}
ROUTE=${ROUTE:-rollouts-demo}
: "${AVI_PASSWORD:?set AVI_PASSWORD}"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ver=$(jq -n --arg u "$AVI_USER" --arg p "$AVI_PASSWORD" '{username:$u,password:$p}' |
  curl -sk --fail -c "$tmp/jar" -H 'Content-Type: application/json' -d @- "$AVI/login" | jq -r .version.Version)
avi() { curl -sk --fail -b "$tmp/jar" -H "X-Avi-Version: $ver" -H "X-Avi-Tenant: $TENANT" "$AVI$1"; }
name() { sed 's/.*#//'; }

# Pools carry markers with the HTTPRoute and backend Service they came from.
pools=$(avi "/api/pool?label_key=HTTPRouteName&label_value=$ROUTE&include_name=true&page_size=100" |
  jq -c --arg ns "$ROUTE_NS" '[.results[] | select(any(.markers[]?; .key=="HTTPRouteNamespace" and (.values|index($ns))))]')
[[ $(jq length <<<"$pools") -gt 0 ]] || { echo "no Avi pools for HTTPRoute $ROUTE_NS/$ROUTE"; exit 1; }

pool_uuids=$(jq -r '.[].uuid' <<<"$pools")
pg=$(avi "/api/poolgroup?include_name=true&page_size=200" |
  jq -c --arg u "$(head -1 <<<"$pool_uuids")" '[.results[] | select(any(.members[]; .pool_ref|contains($u)))][0]')
child=$(avi "/api/virtualservice?pool_group_ref.uuid=$(jq -r .uuid <<<"$pg")&include_name=true" | jq -c '.results[0]')
[[ $child != null ]] || child=$(avi "/api/virtualservice?include_name=true&page_size=200" |
  jq -c --arg u "$(jq -r .uuid <<<"$pg")" '[.results[] | select((.pool_group_ref//"")|contains($u))][0]')
parent=$(jq -r '.vh_parent_vs_ref' <<<"$child" | name)

echo "Parent VS (EVH, owns the VIP): $parent"
echo "Child VS:  $(jq -r .name <<<"$child")"
echo "  match:   $(jq -r '[.vh_matches[] | .host + " " + ([.rules[].matches.path.match_str[]] | join(","))] | join("; ")' <<<"$child")"
echo "Pool group: $(jq -r .name <<<"$pg")"
jq -r --argjson pools "$pools" '.members[] as $m | ($pools[] | select(.uuid as $u | $m.pool_ref|contains($u))) as $p |
  "  ratio \($m.ratio)\t\($p.markers[]|select(.key=="BackendName").values[0])\t\($p.lb_algorithm)\t\([$p.servers[]? | "\(.ip.addr):\(.port)"] | join(" "))"' <<<"$pg"
