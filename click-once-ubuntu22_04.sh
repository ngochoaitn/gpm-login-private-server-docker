#!/bin/bash

##############################################
# RUN FIRST: chmod +x click-once-ubuntu22_04.sh
##############################################

# Check if Docker is installed or not
if ! command -v docker-compose &> /dev/null
then
    echo "Installing docker-compose"

    echo "Updating package list and installing prerequisites..."
    sudo apt update
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

    echo "Adding Docker GPG key..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo "Adding Docker repository..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    echo "Updating package list and installing Docker..."
    sudo apt update
    sudo apt -y install docker-ce

    echo "Installing Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose

    echo "Adding user to docker group..."
    sudo usermod -aG docker $USER

    echo "Creating Docker Compose service..."

sudo tee /etc/systemd/system/docker-compose-app.service > /dev/null << 'EOF'
[Unit]
Description=Docker Compose Application
After=network.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/bin/docker-compose -f /path/to/your/docker-compose.yml up
ExecStop=/usr/local/bin/docker-compose -f /path/to/your/docker-compose.yml down

[Install]
WantedBy=multi-user.target
EOF
    echo "Reloading systemd configuration..."
    sudo systemctl daemon-reload

    echo "Starting and enabling Docker Compose service..."
    sudo systemctl start docker-compose-app
    sudo systemctl enable docker-compose-app

    echo "Docker and Docker Compose installation completed."
    echo "Please log out and log back in for the group changes to take effect."
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

echo Done. Private server url: http://machine_ip, eg: http://127.0.0.1
