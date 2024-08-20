#!/bin/bash

# ##############################################
# RUN FIRST: chmod +x click-once-mac.sh
##############################################
# Check if Docker is installed or not
if ! command -v docker-compose &> /dev/null || ! command -v docker &> /dev/null
then
    echo "Docker desktop is not installed."
    exit 1
fi

if [ ! -f .env ]; then
    cp .env.example .env
fi

# Generate a random password (12 characters, using lowercase letters and numbers)
RANDOM_PASSWORD=""
for i in {1..12}; do
    rand=$((RANDOM % 36))
    if [ $rand -lt 10 ]; then
        randchar=$(printf "\\$(printf '%03o' $((rand + 48)))")
    else
        randchar=$(printf "\\$(printf '%03o' $((rand + 87)))")
    fi
    RANDOM_PASSWORD="${RANDOM_PASSWORD}${randchar}"
done

# Check for .env file
if [ -f .env ]; then
    # Check if DB_PASSWORD exists and is set to 'password'
    if grep -q "^DB_PASSWORD=password" .env; then
        # Update the password in the .env file
        # sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$RANDOM_PASSWORD/" .env
        sed -i.bak "s/^DB_PASSWORD=.*/DB_PASSWORD=${RANDOM_PASSWORD}/" .env
        echo "DB_PASSWORD updated in .env"

        # Display the newly generated password
        echo "Random password: $RANDOM_PASSWORD"
    else
        echo "DB_PASSWORD is already set in .env"
    fi
else
    echo .env file not found
fi

# Restart Docker Compose with the new password
# docker-compose down
docker-compose pull
docker-compose up -d

CURRENT_DIR=$(basename "$PWD")
echo "Current directory: $CURRENT_DIR"
docker exec -it "${CURRENT_DIR}-web-1" chmod 777 /var/www/html/.env
docker exec -it "${CURRENT_DIR}-web-1" chmod 777 /var/www/html/storage
# Check if APP_KEY is empty in .env file
if grep -q "^APP_KEY=$" .env; then
    echo create APP_KEY
    docker exec -it "${CURRENT_DIR}-web-1" php artisan key:generate
fi

echo Done. Private server url: http://machine_ip, eg: http://127.0.0.1
