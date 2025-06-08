# kong/Dockerfile

# Start from the official Kong OSS image
FROM kong:3.7-ubuntu

# Switch to root user to install curl
USER root

# Install curl for the wait script, then clean up
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Switch back to the non-root kong user for security
USER kong