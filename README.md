[![en](https://img.shields.io/badge/Language-English-blue.svg)](https://github.com/ngochoaitn/gpm-login-private-server-docker/blob/main/README.md)
[![vi](https://img.shields.io/badge/Ng%C3%B4n%20ng%E1%BB%AF-Ti%E1%BA%BFng%20Vi%E1%BB%87t-red.svg)](https://github.com/ngochoaitn/gpm-login-private-server-docker/blob/main/README.vi.md)

# Tested on Ubuntu 22.04, mac M1, Windows 11
- Private server: default port 80
- phpMyAdmin: default port 8081

## Installation steps for each operating system
#### Ubuntu 22.04
- Step 1: Run the command (you may need to use sudo)
```
sudo apt install -y git
git clone https://github.com/ngochoaitn/gpm-login-private-server-docker.git
cd gpm-login-private-server-docker
chmod +x click-once-ubuntu-22-04.sh
./click-once-ubuntu-22-04.sh
```
- Step 2 (optional): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting"in the GUI.

#### Windows
- Step 1: Install [Docker desktop](https://www.docker.com/products/docker-desktop/) (verify by running the commands `docker --version` and `docker-compose --version`)
- Step 2: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 3: (optional): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting" in the GUI.
- Step 4 (optional): Enable Docker to start automatically on system startup
- Step 5 (optional): Change the Docker resource path

#### macOS
- Step 1: Install [Docker desktop](https://www.docker.com/products/docker-desktop/) (verify by running the commands `docker --version` and `docker-compose --version`)
- Step 2: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 3: Run the command (you may need to use sudo)
```
chmod +x click-once-mac.sh
./click-once-mac.sh
```
- Step 4: (optional): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting"in the GUI.
- Step 5 (optional): Enable Docker to start automatically on system startup
- Step 6 (optional): Change the Docker resource path

#### Full step use for other OS
- Step 1: Install [Docker desktop](https://www.docker.com/products/docker-desktop/) (verify by running the commands `docker --version` and `docker-compose --version`)
- Step 2: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 3: Copy `.env.example` to `.env`
- Step 4: Change `DB_PASSWORD` in `.env` file
- Step 5: Run the command (you may need to use sudo)
```
docker-compose pull
docker-compose up -d

docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/.env
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/storage
docker exec -it gpm-login-private-server-docker-web-1 php artisan key:generate
```
- Step 6: (optional): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting"in the GUI.
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
Open the terminal and run the following command (you may need to use sudo):
```
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/.env
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/storage
```
