# OMS-Web - Node.js Frontend Development Dockerfile
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
# Note: Using --legacy-peer-deps for npm to handle peer dependency conflicts
# (e.g., eslint-plugin-prettier@4.2.1 with eslint@9.x)
RUN echo "=== Package files in container ===" && ls -la && \
    if [ -f yarn.lock ]; then \
        echo "=== Installing with yarn ===" && \
        yarn install || exit 1; \
    elif [ -f package-lock.json ]; then \
        echo "=== Installing with npm ci --legacy-peer-deps ===" && \
        npm ci --legacy-peer-deps || exit 1; \
    elif [ -f package.json ]; then \
        echo "=== Installing with npm install --legacy-peer-deps ===" && \
        npm install --legacy-peer-deps || exit 1; \
    else \
        echo "ERROR: No package.json found"; \
        exit 1; \
    fi

# Copy the rest of the application
COPY . .

# Expose port for OMS-Web
EXPOSE 8182

# Environment variables for development
ENV NODE_ENV=development
ENV PORT=8182

# Start the application in development mode
# Auto-detect available dev script (dev > start > serve)
CMD ["sh", "-c", "echo '=== Available npm scripts ===' && npm run 2>/dev/null || true && echo '=== Starting application ===' && if grep -q '\"dev\"' package.json 2>/dev/null; then npm run dev; elif grep -q '\"start\"' package.json 2>/dev/null; then npm run start; elif grep -q '\"serve\"' package.json 2>/dev/null; then npm run serve; else echo 'ERROR: No dev/start/serve script found in package.json' && cat package.json && exit 1; fi"]
