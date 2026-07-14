# Shared semantic assertions for SHA-pinned workflow actions.

assert_action_pin() {
  local block=$1
  local target=$2
  local matches

  matches=$(printf '%s\n' "$block" | awk -v target="$target" '
    {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+uses:[[:space:]]*/, "", line)
      sub(/^[[:space:]]*uses:[[:space:]]*/, "", line)

      separator = index(line, " # ")
      if (separator == 0) {
        next
      }

      ref = substr(line, 1, separator - 1)
      comment = substr(line, separator + 3)
      if (index(ref, target "@") != 1) {
        next
      }

      sha = substr(ref, length(target) + 2)
      if (sha ~ /^[0-9a-f]{40}$/ && comment ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {
        count++
      }
    }
    END { print count + 0 }
  ')

  if [ "$matches" -ne 1 ]; then
    printf 'expected exactly one semantic action pin for:\n%s\n' "$target"
    return 1
  fi
}
