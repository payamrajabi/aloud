#!/bin/zsh
# No mutations: print the setup plan, or inspect an already-authorized test account.
set -euo pipefail
node "${0:A:h}/stripe-setup.mjs" "$@"
