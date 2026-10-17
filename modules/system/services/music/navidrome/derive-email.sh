# The local account's email is derived from the realm user, never invented:
#
#   realm email  -> used as-is (any domain)
#   email-shaped username -> used as-is (any domain)
#   bare username -> username@DOMAIN, only when a domain is configured
#   anything else -> no email (the account is still created)
#
# Prints the address, or nothing when the account cannot yield a valid one.
derive_email() {
  local username=$1 email=$2 domain=$3

  if [ -n "$email" ]; then
    printf '%s' "$email"
    return 0
  fi

  if [[ $username =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    printf '%s' "$username"
    return 0
  fi

  if [ -n "$domain" ] && [[ $username =~ ^[A-Za-z0-9._+-]+$ ]]; then
    printf '%s@%s' "$username" "$domain"
  fi
}
