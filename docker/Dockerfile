#
# Unifra APISIX - Zero Intrusion Docker Image
#
# This image adds Unifra plugins to the official Apache APISIX image.
# No modifications to APISIX core - plugins are loaded via extra_lua_path.
#
# Usage:
#   docker run -v ./config.yaml:/usr/local/apisix/conf/config.yaml ghcr.io/unifralabs/apisix:latest
#

ARG APISIX_VERSION=3.14.0-debian
FROM apache/apisix:${APISIX_VERSION}

LABEL org.opencontainers.image.title="Unifra APISIX"
LABEL org.opencontainers.image.description="Apache APISIX with Unifra JSON-RPC gateway plugins"
LABEL org.opencontainers.image.source="https://github.com/unifralabs/apisix"

# Switch to root to copy files
USER root

# Copy Unifra library modules
COPY --chmod=644 unifra /opt/unifra-apisix/unifra

# Copy APISIX plugins (must be in apisix/plugins/ path for APISIX to find them)
COPY --chmod=644 apisix/plugins /opt/unifra-apisix/apisix/plugins

# Copy configuration files
COPY --chmod=644 conf /opt/unifra-apisix/conf

# Ensure directories are readable
RUN chmod 755 /opt/unifra-apisix \
    /opt/unifra-apisix/unifra \
    /opt/unifra-apisix/unifra/jsonrpc \
    /opt/unifra-apisix/unifra/control_plane \
    /opt/unifra-apisix/apisix \
    /opt/unifra-apisix/apisix/plugins \
    /opt/unifra-apisix/conf 2>/dev/null || true

# Switch back to apisix user
USER apisix

# The config.yaml must set extra_lua_path to load these plugins:
#   apisix:
#     extra_lua_path: "/opt/unifra-apisix/?.lua"
