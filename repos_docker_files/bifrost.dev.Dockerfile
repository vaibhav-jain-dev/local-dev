# Bifrost - Next.js Frontend Development Dockerfile
FROM node:18-alpine

WORKDIR /app

# Build argument for GitHub npm registry authentication
# Required for @orange-health packages from GitHub Package Registry
ARG GITHUB_NPM_TOKEN

# Install build dependencies for native npm packages
RUN apk add --no-cache \
    git \
    python3 \
    make \
    g++ \
    libc6-compat

# Copy all package files (use .dockerignore to exclude unwanted files)
COPY package*.json ./
COPY yarn.lock* ./

# Configure npm for GitHub Package Registry authentication
# This creates .npmrc with the token for @orange-health scope
RUN if [ -n "$GITHUB_NPM_TOKEN" ]; then \
        echo "=== Configuring GitHub npm registry for @orange-health ===" && \
        echo "@orange-health:registry=https://npm.pkg.github.com" >> .npmrc && \
        echo "//npm.pkg.github.com/:_authToken=${GITHUB_NPM_TOKEN}" >> .npmrc && \
        echo "=== .npmrc configured ==="; \
    else \
        echo "WARNING: GITHUB_NPM_TOKEN not set - private @orange-health packages may fail to install"; \
    fi

# Install dependencies - try yarn first, then npm
# Using separate RUN to get better error visibility
RUN echo "=== Package files in container ===" && ls -la && \
    if [ -f yarn.lock ]; then \
        echo "=== Installing with yarn ===" && \
        yarn install || exit 1; \
    elif [ -f package-lock.json ]; then \
        echo "=== Installing with npm ci ===" && \
        npm ci || exit 1; \
    elif [ -f package.json ]; then \
        echo "=== Installing with npm install ===" && \
        npm install || exit 1; \
    else \
        echo "ERROR: No package.json found"; \
        exit 1; \
    fi

# Copy the rest of the application
COPY . .

# Expose port for Next.js (configurable via PORT env var)
EXPOSE 3000

# Environment variables for development
ENV NODE_ENV=development
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000

# Start Next.js in development mode with hot reload
# Run next dev directly with PORT env var to override any hardcoded port in package.json
CMD ["sh", "-c", "echo '=== Available npm scripts ===' && npm run 2>/dev/null || true && echo '=== Starting application on port ${PORT} ===' && npx next dev -p ${PORT}"]
