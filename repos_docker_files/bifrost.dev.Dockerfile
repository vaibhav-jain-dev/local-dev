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

# Copy all package files (use .dockerignore to exclude unwanted files)
COPY package*.json ./
COPY yarn.lock* ./

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

# Expose port for Next.js
EXPOSE 3000

# Environment variables for development
ENV NODE_ENV=development
ENV NEXT_TELEMETRY_DISABLED=1

# Start Next.js in development mode with hot reload
# Auto-detect available dev script (dev > start)
CMD ["sh", "-c", "echo '=== Available npm scripts ===' && npm run 2>/dev/null || true && echo '=== Starting application ===' && if grep -q '\"dev\"' package.json 2>/dev/null; then npm run dev; elif grep -q '\"start\"' package.json 2>/dev/null; then npm run start; else echo 'ERROR: No dev/start script found in package.json' && cat package.json && exit 1; fi"]
