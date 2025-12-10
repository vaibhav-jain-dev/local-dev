# Bifrost - Next.js Frontend Development Dockerfile
FROM node:18-alpine

WORKDIR /app

# Install build dependencies for native npm packages
RUN apk add --no-cache \
    git \
    python3 \
    make \
    g++ \
    libc6-compat

# Copy package files first for better caching
# Note: Using explicit file names to fail fast if missing
COPY package.json ./
COPY package-lock.json* yarn.lock* ./

# Install dependencies with verbose error output
RUN set -ex && \
    echo "=== Checking for package files ===" && \
    ls -la package*.json yarn.lock 2>/dev/null || true && \
    if [ -f yarn.lock ]; then \
        echo "=== Installing with yarn (frozen-lockfile) ===" && \
        yarn install --frozen-lockfile --verbose 2>&1 || { echo "Yarn install failed with exit code $?"; exit 1; }; \
    elif [ -f package-lock.json ]; then \
        echo "=== Installing with npm ci ===" && \
        npm ci 2>&1 || { echo "npm ci failed with exit code $?"; exit 1; }; \
    elif [ -f package.json ]; then \
        echo "=== Installing with npm install ===" && \
        npm install 2>&1 || { echo "npm install failed with exit code $?"; exit 1; }; \
    else \
        echo "ERROR: No package.json found - this is likely a build context issue"; \
        echo "Build context files:"; \
        ls -la; \
        exit 1; \
    fi

# Copy the rest of the application
COPY . .

# Expose port for Next.js
EXPOSE 3000

# Environment variables for development
ENV NODE_ENV=development
ENV NEXT_TELEMETRY_DISABLED=1

# Start Next.js in development mode with hot reload
CMD ["npm", "run", "dev"]
