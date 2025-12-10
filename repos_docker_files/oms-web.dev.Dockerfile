# OMS-Web - Node.js Frontend Development Dockerfile
# Based on production Dockerfile but optimized for local development with hot reload
FROM node:14.15.5-alpine3.13

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache \
    git \
    python3 \
    make \
    g++ \
    bash

# Copy package files for dependency installation
COPY package.json ./
COPY package-lock.json ./

# Install dependencies
RUN npm install

# Copy config sample (will be overwritten by mounted volume in dev)
COPY config/config.js.sample config/config.js 2>/dev/null || true

# Copy the rest of the application
COPY . .

# Expose port for OMS-Web
EXPOSE 8182

# Environment variables for development
ENV NODE_ENV=development
ENV PORT=8182

# Start the application in development mode with hot reload
# Use webpack dev server for hot module replacement
CMD ["npm", "run", "dev"]
