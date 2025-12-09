# OMS-Web - Node.js Frontend Development Dockerfile
FROM node:18-alpine

WORKDIR /app

# Install dependencies for development
RUN apk add --no-cache git

# Copy package files first for better caching
COPY package*.json ./
COPY yarn.lock* ./

# Install dependencies
RUN if [ -f yarn.lock ]; then yarn install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then npm ci; \
    else npm install; fi

# Copy the rest of the application
COPY . .

# Expose port for OMS-Web
EXPOSE 8182

# Environment variables for development
ENV NODE_ENV=development
ENV PORT=8182

# Start the application in development mode
CMD ["npm", "run", "dev"]
