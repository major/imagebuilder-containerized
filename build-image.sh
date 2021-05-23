#!/bin/bash
set -euo pipefail

BLUEPRINT_NAME=centos-base
SHIP_TO_AWS=yes

docker-exec () {
    docker exec -t imagebuilder $@
}

composer-cli () {
    docker-exec composer-cli $@
}

IMAGE_UUID=$(docker-exec uuid)

# Start the docker container.
docker run --detach --rm --privileged \
    -v $(pwd)/shared:/repo \
    --name imagebuilder \
    imagebuilder

# Wait for composer to be fully running.
for i in `seq 1 10`; do
    sleep 1
    composer-cli status show && break
done

# Push the blueprint and depsolve.
composer-cli blueprints push /repo/${BLUEPRINT_NAME}-blueprint.toml
composer-cli blueprints depsolve ${BLUEPRINT_NAME} > /dev/null
composer-cli blueprints list

# Start the build.
if [[ $SHIP_TO_AWS == "yes" ]]; then
    composer-cli --json compose start ${BLUEPRINT_NAME} ami github-actions-${IMAGE_UUID} /repo/aws-config.toml | tee compose_start.json
else
    composer-cli --json compose start ${BLUEPRINT_NAME} ami | tee compose_start.json
fi

COMPOSE_ID=$(jq -r '.build_id' compose_start.json)

# Watch the logs while the build runs.
docker-exec journalctl -af -n0 &

while true; do
    composer-cli --json compose info "${COMPOSE_ID}" | tee compose_info.json > /dev/null
    COMPOSE_STATUS=$(jq -r '.queue_status' compose_info.json)

    # Is the compose finished?
    if [[ $COMPOSE_STATUS != RUNNING ]] && [[ $COMPOSE_STATUS != WAITING ]]; then
        echo "Compose finished."
        break
    fi
    sleep 5
done

if [[ $COMPOSE_STATUS != FINISHED ]]; then
    composer-cli compose logs ${COMPOSE_ID}
    docker-exec tar -axf /${COMPOSE_ID}-logs.tar logs/osbuild.log -O
    echo "Something went wrong with the compose. 😢"
    exit 1
fi
