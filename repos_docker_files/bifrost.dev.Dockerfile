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

# Install dependencies (only if package.json exists)
RUN if [ -f yarn.lock ]; then \
        yarn install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then \
        npm ci; \
    elif [ -f package.json ]; then \
        npm install; \
    else \
        echo "No package.json found - skipping dependency install"; \
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
