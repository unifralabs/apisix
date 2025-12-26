#!/bin/bash
#
# Development environment setup script
# Run this once to prepare your local environment for testing
#

set -e

echo "========================================"
echo " Unifra APISIX Development Setup"
echo "========================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# Check prerequisites
echo "Checking prerequisites..."

# Docker
if command -v docker &> /dev/null; then
    success "Docker installed: $(docker --version | head -1)"
else
    error "Docker not found. Please install Docker first."
    exit 1
fi

# Docker Compose
if command -v docker-compose &> /dev/null; then
    success "Docker Compose installed: $(docker-compose --version)"
else
    warn "docker-compose not found, checking for 'docker compose'..."
    if docker compose version &> /dev/null; then
        success "Docker Compose (plugin) installed"
    else
        error "Docker Compose not found. Please install it."
        exit 1
    fi
fi

# Lua
if command -v lua &> /dev/null; then
    success "Lua installed: $(lua -v 2>&1 | head -1)"
else
    warn "Lua not found. Unit tests require Lua."
fi

# LuaRocks
if command -v luarocks &> /dev/null; then
    success "LuaRocks installed: $(luarocks --version | head -1)"
else
    warn "LuaRocks not found. Installing test dependencies may fail."
    echo "  Install with: brew install luarocks (macOS) or apt install luarocks (Ubuntu)"
fi

# Busted
if command -v busted &> /dev/null; then
    success "Busted installed"
else
    warn "Busted not found. Attempting to install..."
    if command -v luarocks &> /dev/null; then
        luarocks install --local busted
        success "Busted installed via LuaRocks"
    else
        warn "Cannot install Busted without LuaRocks"
        echo "  Install manually: luarocks install busted"
    fi
fi

echo ""
echo "Setting up test environment..."

# Verify Docker services can start
echo "Testing Docker environment..."
cd test-env
docker-compose config > /dev/null 2>&1 && success "Docker Compose config valid" || error "Docker Compose config invalid"
cd ..

# Create local LuaRocks tree if needed
if [ ! -d "$HOME/.luarocks" ]; then
    mkdir -p "$HOME/.luarocks"
    success "Created local LuaRocks directory"
fi

# Install additional Lua dependencies
echo ""
echo "Installing Lua dependencies..."
if command -v luarocks &> /dev/null; then
    luarocks install --local luafilesystem 2>/dev/null && success "luafilesystem" || warn "luafilesystem (may already exist)"
    luarocks install --local lua-cjson 2>/dev/null && success "lua-cjson" || warn "lua-cjson (may already exist)"
fi

echo ""
echo "========================================"
echo " Setup Complete!"
echo "========================================"
echo ""
echo "Available commands:"
echo "  make test-unit          # Run unit tests (fast)"
echo "  make test-component     # Run component tests (with Redis)"
echo "  make test-integration   # Run integration tests (full stack)"
echo "  make test-all           # Run all tests"
echo ""
echo "Quick start:"
echo "  1. Run unit tests:      make test-unit"
echo "  2. Start test env:      make docker-up"
echo "  3. Run all tests:       make test-all"
echo ""
