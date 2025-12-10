# Bifrost - Next.js Frontend Development Dockerfile
# Based on production Dockerfile but optimized for local development with hot reload
FROM node:18.20.0

# Set environment for development
ENV ENV=development
ENV NODE_ENV=development

# Install vim for debugging purposes (same as production)
RUN apt-get update && apt-get install -y \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /usr/src/app

# Copy package files for dependency installation
COPY package*.json ./

# GitHub Personal Access Token for private npm packages
# Pass at build time: --build-arg GITHUB_TOKEN=xxx
ARG GITHUB_TOKEN

# Install dependencies with private npm registry access
RUN if [ -n "$GITHUB_TOKEN" ]; then \
        echo "//npm.pkg.github.com/:_authToken=$GITHUB_TOKEN" > .npmrc && \
        npm install && \
        rm -f .npmrc; \
    else \
        npm install; \
    fi

# Copy the rest of the application
COPY . .

# Expose port for Next.js
EXPOSE 3000

# Environment variables for development
ENV NEXT_TELEMETRY_DISABLED=1
ENV WATCHPACK_POLLING=true

# Start in development mode with hot reload
CMD ["npm", "run", "dev"]
