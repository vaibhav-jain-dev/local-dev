# OMS-Web - Node.js Frontend Development Dockerfile
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

# Expose port for OMS-Web
EXPOSE 8182

# Environment variables for development
ENV NODE_ENV=development
ENV PORT=8182

# Start the application in development mode
CMD ["npm", "run", "dev"]
