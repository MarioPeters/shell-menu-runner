# ==============================================================================
#  Shell Menu Runner - Docker Image
#  Lightweight container for running shell-menu-runner
# ==============================================================================

FROM alpine:3.19

LABEL maintainer="Mario Peters <mail@example.com>" \
      version="1.7.0" \
      description="Interactive task menu runner for shell projects" \
      org.opencontainers.image.source="https://github.com/MarioPeters/shell-menu-runner"

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    git \
    ncurses \
    coreutils \
    grep \
    sed \
    findutils \
    && rm -rf /var/cache/apk/*

# Create user for running tasks
RUN addgroup -S runuser && adduser -S runuser -G runuser

# Copy runner script
COPY dist/run-prod.sh /usr/local/bin/run
RUN chmod +x /usr/local/bin/run

# Copy completions (optional)
COPY completions/_run /usr/share/zsh/site-functions/_run 2>/dev/null || true

# Create workspace directory
RUN mkdir -p /workspace && chown runuser:runuser /workspace

# Switch to non-root user
USER runuser
WORKDIR /workspace

# Set default command
ENTRYPOINT ["/usr/local/bin/run"]
CMD ["--help"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD /usr/local/bin/run --version || exit 1

# Metadata
ENV RUN_VERSION="1.7.0" \
    RUN_CONTAINER="1"
