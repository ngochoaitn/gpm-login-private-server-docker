#!/bin/bash

# Generate a random password (12 characters, using lowercase letters and numbers)
RANDOM_PASSWORD=$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)

# Check for .env file
if [ -f .env ]; then
    # Check if DB_PASSWORD exists and is set to 'password'
    if grep -q "^DB_PASSWORD=password" .env; then
        # Backup the .env file
        cp .env .env.bak

        # Update the password in the .env file
        sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$RANDOM_PASSWORD/" .env
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
docker-compose up -d

# Wait for MySQL to start
sleep 5
