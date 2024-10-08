[![en](https://img.shields.io/badge/Language-English-blue.svg)](https://github.com/ngochoaitn/gpm-login-private-server-docker/blob/main/README.md)
[![vi](https://img.shields.io/badge/Ng%C3%B4n%20ng%E1%BB%AF-Ti%E1%BA%BFng%20Vi%E1%BB%87t-red.svg)](https://github.com/ngochoaitn/gpm-login-private-server-docker/blob/main/README.vi.md)

# Tested on Ubuntu 22.04, mac M1, Windows 11
- Private server: default port 80
    - Default username: administrator
    - Default password: administrator
- phpMyAdmin: default port 8081
    - Default username: root
    - Default password: {random in file .env}

## Requirement
#### Storing profile on S3 (recommend)
- RAM >= 1GB
- CPU >= 1 core
- Free disk space >= 5GB
#### Storing profile on host
- RAM >= 2GB
- CPU >= 2core
- Free disk space >= 80GB (based on the number of profiles)

## Installation steps for each operating system
#### Ubuntu 22.04
- Step 1: Run the command (you may need to use sudo)
```
sudo apt install -y git
git clone https://github.com/ngochoaitn/gpm-login-private-server-docker.git
cd gpm-login-private-server-docker
chmod +x click-once-ubuntu-22-04.sh
sudo ./click-once-ubuntu-22-04.sh
```
- Step 2 (optional, recommend): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting" in the web GUI.

#### Windows
- Step 1: Install [Docker desktop](https://www.docker.com/products/docker-desktop/) (verify by running the commands `docker --version` and `docker-compose --version`)
- Step 2: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 3: Double click file `click-once-windows.bat`
- Step 4: (optional, recommend): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting" in the web GUI.
- Step 5 (optional): Enable Docker to start automatically on system startup
- Step 6 (optional): Change the Docker resource path

#### macOS
- Step 1: Install [Docker desktop](https://www.docker.com/products/docker-desktop/) (verify by running the commands `docker --version` and `docker-compose --version`)
- Step 2: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 3: Run the command (you may need to use sudo)
```
chmod +x click-once-mac.sh
./click-once-mac.sh
```
- Step 4: (optional, recommend): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting" in the web GUI.
- Step 5 (optional): Enable Docker to start automatically on system startup
- Step 6 (optional): Change the Docker resource path

#### Full step use for other OS (Ubuntu, CentOS, Debian, Linux...)
- Step 1: Install Docker and Docker compose (verify by running the commands `docker --version` and `docker-compose --version`)
- Step 2: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 3: Copy `.env.example` to `.env`
- Step 4: Change `DB_PASSWORD` in `.env` file
- Step 5: Run the command (you may need to use sudo)
Replace `gpm-login-private-server-docker` with the current folder name.
```
docker-compose pull
docker-compose up -d

docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/.env
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/storage
docker exec -it gpm-login-private-server-docker-web-1 php artisan key:generate
```
- Step 6: (optional, recommend): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting" in the web GUI.
- Step 7 (optional): Enable Docker to start automatically on system startup
- Step 8 (optional): Change the Docker resource path

## Custom port web and phpMyAdmin
- Step1: Change WEB_PORT and PMA_PORT in .env file
- Step 2: Run command
```
docker-compose pull
docker-compose up -d
```

## Fix "Permission Denied" Error on Web
Open the terminal and run the following command (you may need to use sudo). Replace `gpm-login-private-server-docker` with the current folder name.
```
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/.env
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/storage
```

## Error 500 after automatic update on Docker
Open the Docker web terminal and run the command
```
composer dump-autoload
```

## Fix NAS Synology
- Step 1: Edit file .env set user database is root, and leave bank password
- Step 2: Open terminal Docker web
- Step 3: run command
```
apt-get update
apt-get install nano
nano etc/supervisor/conf.d/supervisord.conf
```
- Step 4: change %(SUPERVISOR_PHP_USER)s to root and save (ctrl + X)
- Step 5: run start-container