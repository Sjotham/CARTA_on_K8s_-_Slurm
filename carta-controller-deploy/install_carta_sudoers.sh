# Be very careful this this script "Please only edit your sudoers configuration with visudo or equivalent."

#!/usr/bin/env bash
set -euo pipefail

TARGET="/etc/sudoers.d/carta_controller"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Ensure the drop-in directory exists
sudo install -d -o root -g root -m 755 /etc/sudoers.d

# Write desired sudoers content to a temp file
cat >"$TMP" <<'EOF'
# customise this file to fit your environment using visudo /etc/sudoers.d/carta_controller

# carta user can run the carta_backend command as any user in the carta-users group without entering password
carta ALL=(%carta-users) NOPASSWD:SETENV: /usr/bin/carta_backend

# carta user can run the kill script as any user in the carta-users group without entering password
carta ALL=(%carta-users) NOPASSWD: /usr/bin/carta-kill-script
EOF

# Validate syntax BEFORE installing
sudo visudo -cf "$TMP" >/dev/null

# Install atomically with correct perms
sudo install -o root -g root -m 0440 "$TMP" "$TARGET"

# Final sanity check of the whole config
sudo visudo -cf /etc/sudoers >/dev/null

echo "Installed: $TARGET"

