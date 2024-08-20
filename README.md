# Tested on Ubuntu 22.04, mac M1, Windows 11
- Private server: default port 80
- phpMyAdmin: default port 8081

## Installation steps for each operating system
#### Ubuntu 22.04
- Step 1: Run the command
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
- Step 2 (optional): Change the Docker resource path
- Step 3: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 5: (optional): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting" in the GUI.
- Step 6 (optional): Enable Docker to start automatically on system startup

#### macOS
- Step 1: Install [Docker desktop](https://www.docker.com/products/docker-desktop/) (verify by running the commands `docker --version` and `docker-compose --version`)
- Step 2: Change the Docker resource path (optional)
- Step 3: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 4: Run the command (you may need to use sudo)
```
chmod +x click-once-mac.sh
./click-once-mac.sh
```
- Step 5: (optional): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting"in the GUI.
- Step 6 (optional): Enable Docker to start automatically on system startup

#### Full step use for other OS
- Step 1: Install [Docker desktop](https://www.docker.com/products/docker-desktop/) (verify by running the commands `docker --version` and `docker-compose --version`)
- Step 2 (optional): Change the Docker resource path
- Step 3: [Download](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) or clone this repository
- Step 4: Copy `.env.example` to `.env`
- Step 5: Change `DB_PASSWORD` in `.env` file
- Step 6: Run the command (you may need to use sudo)
```
docker-compose pull
docker-compose up -d

docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/.env
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/storage
docker exec -it gpm-login-private-server-docker-web-1 php artisan key:generate
```
- Step 7: (optional): If you want to save the profile on S3, log in to the private server (default port 80) and configure the "Storage setting"in the GUI.
- Step 8 (optional): Enable Docker to start automatically on system startup

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
