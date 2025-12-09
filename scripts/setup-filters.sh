#!/bin/bash
git config filter.masksecrets.clean ".git_filters/mask_secrets.sh"
git config filter.masksecrets.smudge "cat"
echo "Masking filter installed. Run: git add --renormalize ."

