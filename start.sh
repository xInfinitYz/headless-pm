#!/bin/bash

# Headless PM Start Script
# Checks environment, database, and starts the API server

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Banner
echo -e "${BLUE}"
echo "🚀 Headless PM Startup Script"
echo "==============================="
echo -e "${NC}"

# Detect architecture and suggest appropriate venv
ARCH=$(uname -m)
log_info "Detected architecture: $ARCH"

if [[ "$ARCH" == "arm64" ]]; then
    EXPECTED_VENV="venv"
else
    EXPECTED_VENV="claude_venv"
fi

# Check if .env file exists
if [ ! -f ".env" ]; then
    log_error ".env file not found!"
    log_info "Copying env-example to .env..."
    if [ -f "env-example" ]; then
        cp env-example .env
        log_success ".env file created from env-example"
        log_warning "Please edit .env file with your configuration before continuing"
        exit 1
    else
        log_error "env-example file not found! Cannot create .env"
        exit 1
    fi
fi

log_success ".env file found"

# Check if we're in a virtual environment
if [ -n "$VIRTUAL_ENV" ]; then
    log_success "Virtual environment active: $VIRTUAL_ENV"
    # Check if it's the expected venv for this architecture
    if [[ ! "$VIRTUAL_ENV" == *"$EXPECTED_VENV"* ]]; then
        log_warning "You're using a different venv than recommended for $ARCH architecture"
        log_info "Recommended: $EXPECTED_VENV (run ./setup/universal_setup.sh to set up)"
    fi
else
    log_warning "No virtual environment detected!"
    log_info "Please activate the virtual environment:"
    echo "  source $EXPECTED_VENV/bin/activate"
    log_info "Or run ./setup/universal_setup.sh to set up the environment"
fi

# Check Python version
PYTHON_VERSION=$(python --version 2>&1 | cut -d' ' -f2)
PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d'.' -f1)
PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d'.' -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 11 ]); then
    log_error "Python 3.11+ required. Found: $PYTHON_VERSION"
    exit 1
fi

log_success "Python version: $PYTHON_VERSION"

# Check if required packages are installed
log_info "Checking required packages..."
if ! python -c "import fastapi, sqlmodel, uvicorn" 2>/dev/null; then
    log_error "Required packages not found or have compatibility issues!"
    log_info "This often happens with architecture mismatches (ARM64 vs x86_64)"
    log_info "Recommended solution:"
    echo "  Run: ./setup/universal_setup.sh"
    echo "  This will create the correct environment for your architecture ($ARCH)"
    exit 1
else
    log_success "Required packages found"
fi

# Load environment variables from .env file
if [ -f ".env" ]; then
    # Export variables from .env file
    set -a
    source .env
    set +a
    log_success "Environment variables loaded from .env"
else
    log_warning "No .env file found, using defaults"
fi

# Check database configuration
DB_CONNECTION=${DB_CONNECTION:-"sqlite"}
log_info "Database type: $DB_CONNECTION"

# Test database connection
log_info "Testing database connection..."
DB_TEST_OUTPUT=$(python -c "
print('Starting database test...')
from src.models.database import engine
print('Engine imported successfully')
try:
    print('Attempting connection...')
    with engine.connect() as conn:
        print('Connection established')
        pass
    print('SUCCESS')
except Exception as e:
    print(f'FAILED: {e}')
" 2>&1)

log_info "Database test output: $DB_TEST_OUTPUT"

if [[ "$DB_TEST_OUTPUT" == *"SUCCESS"* ]]; then
    log_success "Database connection successful"
elif [[ "$DB_TEST_OUTPUT" == *"FAILED"* ]]; then
    log_warning "Database connection failed. Initializing database..."
    python -m src.cli.main init
    log_success "Database initialized"
else
    log_error "Database test failed with unexpected output"
    log_info "Output was: $DB_TEST_OUTPUT"
    exit 1
fi

# Check if database has tables
log_info "Checking database schema..."
SCHEMA_OUTPUT=$(python -c "
print('Starting schema check...')
from src.models.database import engine
from sqlalchemy import text
print('Schema imports successful')
try:
    print('Connecting to database for schema check...')
    with engine.connect() as conn:
        print('Schema connection established')
        if '$DB_CONNECTION' == 'sqlite':
            result = conn.execute(text(\"SELECT name FROM sqlite_master WHERE type='table'\"))
        else:
            result = conn.execute(text(\"SHOW TABLES\"))
        tables = result.fetchall()
        print(f'Found {len(tables)} tables')
        if len(tables) < 5:  # Expecting at least 5 core tables
            print('INCOMPLETE')
        else:
            print('VALID')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1)

log_info "Schema check output: $SCHEMA_OUTPUT"

if [[ "$SCHEMA_OUTPUT" == *"VALID"* ]]; then
    log_success "Database schema valid"
elif [[ "$SCHEMA_OUTPUT" == *"INCOMPLETE"* ]]; then
    log_warning "Database schema incomplete. Reinitializing..."
    echo "y" | python -m src.cli.main reset 2>/dev/null || true
    python -m src.cli.main init
    log_success "Database reinitialized"
else
    log_error "Schema check failed"
    log_info "Output was: $SCHEMA_OUTPUT"
    exit 1
fi

# Check port availability
PORT=${SERVICE_PORT:-6969}

# Only check port if service will be started
if [ ! -z "$SERVICE_PORT" ] || [ "$PORT" = "6969" ]; then
    log_info "Checking if port $PORT is available..."
    if lsof -i :$PORT >/dev/null 2>&1; then
        log_warning "Port $PORT is already in use"
        log_info "You may want to stop the existing service or use a different port"
    else
        log_success "Port $PORT is available"
    fi
fi

# Only check MCP port if defined
if [ ! -z "$MCP_PORT" ]; then
    log_info "Checking if MCP port $MCP_PORT is available..."
    if lsof -i :$MCP_PORT >/dev/null 2>&1; then
        log_warning "MCP port $MCP_PORT is already in use"
        log_info "You may want to stop the existing service or use a different port"
    else
        log_success "MCP port $MCP_PORT is available"
    fi
fi

# Only check dashboard port if defined
if [ ! -z "$DASHBOARD_PORT" ]; then
    log_info "Checking if dashboard port $DASHBOARD_PORT is available..."
    if lsof -i :$DASHBOARD_PORT >/dev/null 2>&1; then
        log_warning "Dashboard port $DASHBOARD_PORT is already in use"
        log_info "You may want to stop the existing service or use a different port"
    else
        log_success "Dashboard port $DASHBOARD_PORT is available"
    fi
fi

# Function to start MCP server in background
start_mcp_server() {
    log_info "Starting MCP SSE server on port $MCP_PORT..."
    uvicorn src.mcp.simple_sse_server:app --port $MCP_PORT --host 0.0.0.0 2>&1 | sed 's/^/[MCP] /' &
    MCP_PID=$!
    log_success "MCP SSE server started on port $MCP_PORT (PID: $MCP_PID)"
}

# Function to start dashboard in background
start_dashboard() {
    # Check if Node.js is installed
    if ! command -v node >/dev/null 2>&1; then
        log_warning "Node.js not found. Dashboard requires Node.js 18+ to run."
        log_info "Please install Node.js from https://nodejs.org/"
        return
    fi
    
    # Check Node version
    NODE_VERSION=$(node --version | cut -d'v' -f2)
    NODE_MAJOR=$(echo $NODE_VERSION | cut -d'.' -f1)
    if [ "$NODE_MAJOR" -lt 18 ]; then
        log_warning "Node.js 18+ required for dashboard. Found: v$NODE_VERSION"
        return
    fi
    
    if [ -d "dashboard" ]; then
        log_info "Starting dashboard on port $DASHBOARD_PORT..."
        cd dashboard
        
        # Check if node_modules exists
        if [ ! -d "node_modules" ]; then
            log_warning "Dashboard dependencies not installed. Installing..."
            npm install >/dev/null 2>&1
            log_success "Dashboard dependencies installed"
        fi
        
        # Start the dashboard with the configured port
        npx next dev --port $DASHBOARD_PORT --turbopack 2>&1 | sed 's/^/[DASHBOARD] /' &
        DASHBOARD_PID=$!
        cd ..
        log_success "Dashboard started on port $DASHBOARD_PORT (PID: $DASHBOARD_PID)"
    else
        log_warning "Dashboard directory not found. Skipping dashboard startup."
        log_info "To install the dashboard, run: npx create-next-app@latest dashboard"
    fi
}

# Function to cleanup on exit
cleanup() {
    log_info "Shutting down..."
    if [ ! -z "$MCP_PID" ]; then
        kill $MCP_PID 2>/dev/null || true
        log_info "MCP server stopped"
    fi
    if [ ! -z "$DASHBOARD_PID" ]; then
        kill $DASHBOARD_PID 2>/dev/null || true
        log_info "Dashboard stopped"
    fi
    if [ ! -z "$API_PID" ]; then
        kill $API_PID 2>/dev/null || true
        log_info "API server stopped"
    fi
    exit 0
}

# Set up trap for cleanup
trap cleanup INT TERM

# Start the servers
log_info "All checks passed! Starting Headless PM servers..."
echo -e "${GREEN}"
echo "🌟 Starting services..."
if [ ! -z "$SERVICE_PORT" ] || [ "$PORT" = "6969" ]; then
    echo "📚 API Documentation: http://localhost:$PORT/api/v1/docs"
fi
if [ ! -z "$MCP_PORT" ]; then
    echo "🔌 MCP HTTP Server: http://localhost:$MCP_PORT"
fi
if [ ! -z "$DASHBOARD_PORT" ]; then
    echo "🖥️  Web Dashboard: http://localhost:$DASHBOARD_PORT"
fi
echo "📊 CLI Dashboard: python -m src.cli.main dashboard"
echo "🛑 Stop servers: Ctrl+C"
echo -e "${NC}"

# Start MCP server in background (only if MCP_PORT is defined)
if [ ! -z "$MCP_PORT" ]; then
    start_mcp_server
else
    log_info "MCP_PORT not defined in .env, skipping MCP server startup"
fi

# Start dashboard in background (only if DASHBOARD_PORT is defined)
if [ ! -z "$DASHBOARD_PORT" ]; then
    start_dashboard
else
    log_info "DASHBOARD_PORT not defined in .env, skipping dashboard startup"
fi

# Start API server (only if SERVICE_PORT is defined or use default)
if [ ! -z "$SERVICE_PORT" ] || [ "$PORT" = "6969" ]; then
    log_info "Starting API server on port $PORT..."
    uvicorn src.main:app --reload --port $PORT --host 0.0.0.0 &
    API_PID=$!
else
    log_info "SERVICE_PORT not defined in .env, skipping API server startup"
fi

# Wait for all processes
wait $API_PID $MCP_PID $DASHBOARD_PID