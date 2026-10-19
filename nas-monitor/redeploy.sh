#!/bin/sh
set -e
cd /Volume1/public/Docker/dga4130-monitor
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0
export PATH=/Volume1/@apps/DockerEngine/dockerd/bin:$PATH

docker-compose down || true
docker-compose up -d --build
docker-compose ps
echo "--- Log ultimi 30 righe ---"
docker-compose logs --tail 30
