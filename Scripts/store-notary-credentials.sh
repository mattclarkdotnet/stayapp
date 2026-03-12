#!/bin/zsh

set -euo pipefail

PROFILE_NAME="${1:-StayNotary}"

echo "Storing notary credentials for profile '$PROFILE_NAME'."
echo "Follow the prompts from notarytool."

xcrun notarytool store-credentials "$PROFILE_NAME"
