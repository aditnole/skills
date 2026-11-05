#!/usr/bin/env bash
# Claude Code status line — single line, width-aware.
# Items are added in priority order and dropped from the end if the terminal is too narrow.
input=$(cat)
j() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }

R=$'\033[0m'; DIM=$'\033[2m'; B=$'\033[1m'
CY=$'\033[36m'; MG=$'\033[35m'; GR=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'; BL=$'\033[34m'
NOW=$(date +%s)
CACHE=~/.claude/cache/statusline; mkdir -p "$CACHE"

int() { local v=${1%.*}; printf '%d' "${v:-0}" 2>/dev/null || printf 0; }
color_for() { local p=$(int "$1"); if [ "$p" -ge "${3:-80}" ]; then printf '%s' "$RD"; elif [ "$p" -ge "${2:-50}" ]; then printf '%s' "$YL"; else printf '%s' "$GR"; fi; }
human() { local n=$(int "$1"); if [ $n -ge 1000000 ]; then awk "BEGIN{printf \"%.1fM\", $n/1000000}"; elif [ $n -ge 1000 ]; then printf '%dk' $((n/1000)); else printf '%d' $n; fi; }
bar() { local p=$(int "$1") n s="" i; n=$(( (p + 5) / 10 )); [ $n -gt 10 ] && n=10
  for ((i=0;i<10;i++)); do [ $i -lt $n ] && s+="█" || s+="░"; done; printf "%s" "$s"; }
dur() { local d=$1 h m; [ $d -lt 0 ] && d=0; h=$((d/3600)); m=$(((d%3600)/60))
  if [ $h -ge 24 ]; then printf '%dd%dh' $((h/24)) $((h%24)); elif [ $h -gt 0 ]; then printf '%dh%02dm' $h $m; else printf '%dm' $m; fi; }

# Usage limit: "5h 63%▲ ↻3h20m"  (▲ red = will run out before reset at current pace, ~ yellow = close)
limit() { # label used% resets_at window_seconds
  local label=$1 used=$2 reset=$3 win=$4 u left el proj out
  [ -z "$used" ] && return
  u=$(int "$used"); out="${label} $(color_for "$u")${u}%${R}"
  if [ -n "$reset" ]; then
    left=$(( $(int "$reset") - NOW ))
    if [ $left -gt 0 ] && [ $left -le $win ]; then
      el=$(( (win - left) * 100 / win ))
      if [ $el -ge 5 ] && [ $u -ge 10 ]; then
        proj=$(( u * 100 / el ))
        if [ $proj -ge 100 ]; then out+="${RD}▲${R}"; elif [ $proj -ge 85 ]; then out+="${YL}~${R}"; fi
      fi
      [ "$label" = "5h" ] && out+=" ${DIM}↻$(dur $left)${R}"
    fi
  fi
  printf '%s' "$out"
}

# ---------- gather ----------
model=$(j '.model.display_name')
ctx=$(j '.context_window.used_percentage')
ctx_size=$(j '.context_window.context_window_size')
ctx_tokens=$(j '.context_window.total_input_tokens')
cost=$(j '.cost.total_cost_usd'); ms=$(j '.cost.total_duration_ms')
cwd=$(j '.workspace.current_dir'); [ -z "$cwd" ] && cwd=$(j '.cwd')
my_sid=$(j '.session_id')

seg_model="${B}${MG}${model:-Claude}${R}"

seg_ctx=""
if [ -n "$ctx" ]; then
  p=$(int "$ctx"); seg_ctx="ctx $(color_for "$p" 60 80)$(bar "$p") ${p}%${R}"
  if [ -n "$ctx_size" ]; then
    [ -z "$ctx_tokens" ] && ctx_tokens=$(( $(int "$ctx_size") * p / 100 ))
    seg_ctx+=" ${DIM}$(human "$ctx_tokens")${R}"
  fi
  if [ $p -ge 80 ]; then seg_ctx+=" ${RD}${B}⚠compact${R}"; elif [ $p -ge 65 ]; then seg_ctx+=" ${YL}compact soon${R}"; fi
fi

seg_5h=$(limit 5h "$(j '.rate_limits.five_hour.used_percentage')" "$(j '.rate_limits.five_hour.resets_at')" 18000)
seg_7d=$(limit 7d "$(j '.rate_limits.seven_day.used_percentage')" "$(j '.rate_limits.seven_day.resets_at')" 604800)
seg_cost=""; [ -n "$cost" ] && seg_cost="${YL}\$$(printf '%.2f' "$cost")${R}"
seg_dur="";  [ -n "$ms" ] && seg_dur="${DIM}$(dur $(( $(int "$ms") / 1000 )))${R}"

seg_git=""; seg_pr=""; seg_dir=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  seg_dir="${BL}$(basename "$top")${R}"
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  seg_git="${GR}${branch}${R}"
  gd=$(cd "$cwd" && git rev-parse --absolute-git-dir 2>/dev/null)
  gcd=$(cd "$cwd" && cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
  [ -n "$gd" ] && [ -n "$gcd" ] && [ "$gd" != "$gcd" ] && seg_git+="${MG}[wt]${R}"
  if ab=$(git -C "$cwd" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    behind=${ab%%[[:space:]]*}; ahead=${ab##*[[:space:]]}
    [ "$ahead" -gt 0 ] && seg_git+="${GR}↑${ahead}${R}"
    [ "$behind" -gt 0 ] && seg_git+="${RD}↓${behind}${R}"
  fi
  st=$(git -C "$cwd" status --porcelain 2>/dev/null)
  if [ -n "$st" ]; then
    staged=$(grep -c '^[MADRC]' <<<"$st"); mod=$(grep -c '^.[MD]' <<<"$st"); untr=$(grep -c '^??' <<<"$st")
    [ $staged -gt 0 ] && seg_git+=" ${GR}●${staged}${R}"
    [ $mod -gt 0 ] && seg_git+=" ${YL}✚${mod}${R}"
    [ $untr -gt 0 ] && seg_git+=" ${DIM}?${untr}${R}"
  fi

  # PR + CI via gh — cached 60s, refreshed in background so it never blocks
  if command -v gh >/dev/null && [ -n "$branch" ]; then
    key=$(printf '%s' "$top:$branch" | shasum | cut -c1-16); cf="$CACHE/pr-$key"
    mtime=$(stat -f %m "$cf" 2>/dev/null || stat -c %Y "$cf" 2>/dev/null || echo 0)
    if [ $((NOW - mtime)) -gt 60 ] && ! [ -e "$cf.lock" ]; then
      ( touch "$cf.lock"
        res=$(cd "$top" && perl -e 'alarm shift; exec @ARGV' 10 gh pr view --json number,state,isDraft,reviewDecision,statusCheckRollup 2>/dev/null \
          | jq -r '
              [.statusCheckRollup[]? | (.conclusion // .state // .status) | ascii_upcase] as $c |
              (if ($c|length)==0 then "none"
               elif any($c[]; .=="FAILURE" or .=="ERROR" or .=="CANCELLED" or .=="TIMED_OUT" or .=="ACTION_REQUIRED") then "fail"
               elif any($c[]; .=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED" or .=="EXPECTED" or .=="WAITING") then "pending"
               else "pass" end) as $ci |
              "\(.number)\t\(.state)\t\(.isDraft)\t\(.reviewDecision // "")\t\($ci)"')
        printf '%s' "$res" > "$cf"; rm -f "$cf.lock" ) >/dev/null 2>&1 &
      disown 2>/dev/null
    fi
    if [ -s "$cf" ]; then
      IFS=$'\t' read -r num state draft review ci < "$cf"
      case $state in MERGED) seg_pr="${MG}#${num}✔merged${R}";; CLOSED) seg_pr="${DIM}#${num} closed${R}";;
        *) [ "$draft" = "true" ] && seg_pr="${DIM}#${num}draft${R}" || seg_pr="${CY}#${num}${R}"
           case $ci in pass) seg_pr+="${GR}✓${R}";; fail) seg_pr+="${RD}✗${R}";; pending) seg_pr+="${YL}⏳${R}";; esac
           case $review in APPROVED) seg_pr+=" ${GR}approved${R}";; CHANGES_REQUESTED) seg_pr+=" ${RD}changes${R}";; esac;;
      esac
    fi
  fi
elif [ -n "$cwd" ]; then
  seg_dir="${BL}$(basename "$cwd")${R}"
fi

# Sessions: count live ones; flag another session in the same folder
n=0; busy=0; clash=""
for f in ~/.claude/sessions/*.json; do
  [ -e "$f" ] || continue
  pid=$(basename "$f" .json); kill -0 "$pid" 2>/dev/null || continue
  IFS=$'\t' read -r sid name scwd sstatus < <(jq -r '[.sessionId//"", .name//"", .cwd//"", .status//""] | @tsv' "$f" 2>/dev/null)
  n=$((n+1)); [ "$sstatus" = "busy" ] && busy=$((busy+1))
  [ -n "$my_sid" ] && [ "$sid" = "$my_sid" ] && continue
  [ -n "$cwd" ] && [ "$scwd" = "$cwd" ] && clash="${name:-other}"
done
seg_sess=""
if [ $n -gt 1 ]; then seg_sess="${CY}⧉${n}${R}${DIM}(${busy} busy)${R}"; fi
[ -n "$clash" ] && seg_sess+=" ${RD}!${clash} same dir${R}"

# ---------- render to fit width ----------
width=${COLUMNS:-0}
[ "$width" -le 0 ] 2>/dev/null && width=$(stty size 2>/dev/null </dev/tty | awk '{print $2}')
[ -z "$width" ] || [ "$width" -le 0 ] && width=120
max=$(( width - 4 ))

vislen() { local s; s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'); printf '%s' "$s" | wc -m | tr -d ' '; }

SEP=" ${DIM}·${R} "
out=""; len=0
# priority order: most important first
for seg in "$seg_model" "$seg_ctx" "$seg_5h" "$seg_git" "$seg_pr" "$seg_7d" "$seg_cost" "$seg_sess" "$seg_dir" "$seg_dur"; do
  [ -z "$seg" ] && continue
  add=$(vislen "$seg"); [ -n "$out" ] && add=$((add + 3))
  [ $((len + add)) -gt $max ] && break
  out+="${out:+$SEP}${seg}"; len=$((len + add))
done
printf '%s\n' "$out"
