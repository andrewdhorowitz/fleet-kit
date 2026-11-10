#!/data/data/com.termux/files/usr/bin/bash
# file: setup-middleware.sh
# path: ./setup-middleware.sh

set -e

# Termux fixes (Muse, 2026-11-09, after Andrew's run froze three times):
# 1. npx asks "install wrangler?" interactively; inside this script that
#    prompt is invisible (checks redirect output), so the run hangs forever
#    at the login check. npm_config_yes makes npx install without asking.
# 2. Prefer a globally installed wrangler binary when one exists.
export npm_config_yes=true
if command -v wrangler &> /dev/null; then WR="wrangler"; else WR="npx wrangler"; fi

echo "=== Middleware Phase 0: Infrastructure Setup ==="
echo "Checking prerequisites..."

if ! command -v npm &> /dev/null; then
    echo "ERROR: npm is required. Install via 'pkg install nodejs'"
    exit 1
fi

if ! command -v npx &> /dev/null; then
    echo "ERROR: npx is required."
    exit 1
fi

echo "[OK] Prerequisites met."

# Token loading (Muse, 2026-11-09, at Andrew's direction): when cf.out is
# present, read the Cloudflare API token from it — the value is never
# printed. Search order: this folder, then the Termux home directory.
# cf.out is git-ignored; it must never be committed.
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for f in "$SCRIPT_DIR/cf.out" "$HOME/cf.out"; do
        if [ -f "$f" ]; then
            CLOUDFLARE_API_TOKEN=$(head -n 1 "$f" | tr -d ' \t\r\n')
            export CLOUDFLARE_API_TOKEN
            echo "[OK] Loaded Cloudflare token from $f (${#CLOUDFLARE_API_TOKEN} chars)."
            break
        fi
    done
fi
echo "Checking Cloudflare Wrangler login..."
if ! $WR whoami &> /dev/null; then
    echo "Wrangler is not authenticated. On Termux, OAuth login does not work:"; echo "set CLOUDFLARE_API_TOKEN in this session (read -s line) and rerun."
    exit 1
fi
echo "[OK] Wrangler authenticated."

# Step 1: Create project files if they don't exist
if [ ! -f "wrangler.toml" ]; then
    echo "Creating wrangler.toml..."
    cat << 'EOF' > wrangler.toml
name = "andrew-middleware"
main = "src/index.js"
compatibility_date = "2023-10-30"

# D1 Database for Idempotency Ledger and Audit Trail
[[d1_databases]]
binding = "DB"
database_name = "middleware-ledger"
database_id = "TO_BE_FILLED"
EOF
fi

# Step 2: Provision D1 Database (Idempotency requires strong consistency)
echo "Checking D1 database..."
if ! $WR d1 info middleware-ledger &> /dev/null; then
    echo "Creating D1 database 'middleware-ledger'..."
    D1_OUT=$($WR d1 create middleware-ledger)
    echo "$D1_OUT"
    
    DB_ID=$(echo "$D1_OUT" | grep "database_id" | awk -F'"' '{print $4}')
    echo "-> Extracted DB_ID: $DB_ID"
    
    # Safely inject DB_ID into wrangler.toml
    sed -i "s/database_id = \"TO_BE_FILLED\"/database_id = \"$DB_ID\"/g" wrangler.toml
    
    echo "Creating schema..."
    cat << 'EOF' > schema.sql
    CREATE TABLE IF NOT EXISTS ledger (
        request_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        response_json TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    CREATE TABLE IF NOT EXISTS audit (
        audit_id TEXT PRIMARY KEY,
        request_id TEXT NOT NULL,
        caller TEXT NOT NULL,
        action TEXT NOT NULL,
        reason TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    CREATE TABLE IF NOT EXISTS previews (
        preview_id TEXT PRIMARY KEY,
        action TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        expires_at DATETIME NOT NULL
    );
EOF
    $WR d1 execute middleware-ledger --file=schema.sql --remote
else
    echo "[OK] D1 database 'middleware-ledger' already exists."
fi

# Step 3: Secrets Prompt (each secret independent; patched by Muse 2026-11-09
# so an unavailable secret can be skipped without aborting the run)
echo ""
echo "=== Secret Configuration ==="
echo "The middleware uses three secrets. Each is optional tonight:"
echo "1. MUSE_BEARER_TOKEN (for Muse to authenticate to the worker)"
echo "   -> invent a long random string; SAVE IT in 1Password first."
echo "2. GCP_WORKSPACE_SA_KEY (JSON Service Account Key with Domain-Wide"
echo "   Delegation for the Groups API) -> skip if you don't have one yet."
echo "3. WORKSPACE_ADMIN_EMAIL (the admin identity the SA impersonates)"
echo "   -> only needed together with secret 2; skip if you skipped 2."
echo ""
read -p "Set MUSE_BEARER_TOKEN now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    $WR secret put MUSE_BEARER_TOKEN || echo "[skip] MUSE_BEARER_TOKEN not set."
fi
read -p "Set GCP_WORKSPACE_SA_KEY now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    $WR secret put GCP_WORKSPACE_SA_KEY || echo "[skip] GCP_WORKSPACE_SA_KEY not set."
fi
read -p "Set WORKSPACE_ADMIN_EMAIL now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    $WR secret put WORKSPACE_ADMIN_EMAIL || echo "[skip] WORKSPACE_ADMIN_EMAIL not set."
fi

# Step 4: Deploy
echo ""
read -p "Infrastructure ready. Proceed with deployment to Cloudflare edge? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deploying via Wrangler..."
    $WR deploy
    echo "=== DEPLOYMENT COMPLETE ==="
else
    echo "Deployment aborted by owner. Run script again when ready."
fi
