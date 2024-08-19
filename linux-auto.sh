#!/bin/bash

# Run fist: chmod +x update_env.sh

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
if [ -f ".env" ]; then
    # Backup the .env file
    cp .env .env.bak
    # Update the password in the .env file
    sed -i.bak "s/^DB_PASSWORD=.*/DB_PASSWORD=${RANDOM_PASSWORD}/" .env
    echo "DB_PASSWORD updated in .env"
else
    # Create a new .env file
    cat <<EOT > .env
DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=gpmlogin_db
DB_USERNAME=sail
DB_PASSWORD=${RANDOM_PASSWORD}
EOT
    echo "File .env has been created with a random password."
fi

# Display the newly generated password
echo "Random password: ${RANDOM_PASSWORD}"

# Restart Docker Compose with the new password
# docker-compose down
# docker-compose up -d

# Wait for MySQL to start
sleep 5

# Update the root and sail passwords in the MySQL container
docker exec -i gpm-login-private-server-docker-mysql-1 mysql -u root -ppassword -e "ALTER USER 'root'@'%' IDENTIFIED BY '${RANDOM_PASSWORD}'; FLUSH PRIVILEGES;"
docker exec -i gpm-login-private-server-docker-mysql-1 mysql -u root -ppassword -e "ALTER USER 'sail'@'%' IDENTIFIED BY '${RANDOM_PASSWORD}'; FLUSH PRIVILEGES;"
