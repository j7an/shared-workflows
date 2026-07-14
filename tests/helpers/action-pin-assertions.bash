# Shared semantic assertions for SHA-pinned workflow actions.

assert_action_pin() {
  local block=$1
  local target=$2
  local counts
  local reference_count
  local valid_count

  counts=$(printf '%s\n' "$block" | awk -v target="$target" '
    {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+uses:[[:space:]]*/, "", line)
      sub(/^[[:space:]]*uses:[[:space:]]*/, "", line)

      quote = substr(line, 1, 1)
      if (quote == "\"" || quote == "\047") {
        line = substr(line, 2)
      } else {
        quote = ""
      }

      if (index(line, target "@") != 1) {
        next
      }
      reference_count++

      separator = index(line, " # ")
      if (separator == 0) {
        next
      }

      ref = substr(line, 1, separator - 1)
      comment = substr(line, separator + 3)
      if (quote != "") {
        if (substr(ref, length(ref), 1) != quote) {
          next
        }
        ref = substr(ref, 1, length(ref) - 1)
      }
      sha = substr(ref, length(target) + 2)
      if (sha ~ /^[0-9a-f]{40}$/ && comment ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {
        valid_count++
      }
    }
    END { print reference_count + 0, valid_count + 0 }
  ')
  reference_count=${counts%% *}
  valid_count=${counts#* }

  if [ "$reference_count" -ne 1 ] || [ "$valid_count" -ne 1 ]; then
    printf 'expected exactly one semantic action pin for:\n%s\n' "$target"
    return 1
  fi
}
