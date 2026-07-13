#!/usr/bin/env bash
# Point git at the repo's tracked hooks (the personal-data / secret guard).
set -euo pipefail
cd "$(dirname "$0")/.."
chmod +x Scripts/hooks/* 2>/dev/null || true
git config core.hooksPath Scripts/hooks
echo "✓ hooks installed (core.hooksPath = Scripts/hooks)"
if [ ! -f .personal-denylist ]; then
    cat > .personal-denylist <<'EOF'
# Machine-local denylist for the pre-commit guard (gitignored).
# One term per line; lines starting with # are ignored. Case-insensitive.
# Add your username, real emails, employer/domain, and private repo names.
# Examples (replace with your own real values):
# yourusername
# you@example.com
# your-employer-domain
EOF
    echo "✓ created .personal-denylist — add your personal terms to it"
fi
