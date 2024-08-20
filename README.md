# Tested on Ubuntu 22.04, mac M1, Windows 11

## 1. Ubuntu 22.04 (Run in terminal)
```
sudo apt install -y git
git clone https://github.com/ngochoaitn/gpm-login-private-server-docker.git
cd gpm-login-private-server-docker
chmod +x click-once-ubuntu-22-04.sh
./click-once-ubuntu-22-04.sh
```

## 2. Other OS
#### 2.1. Requirement
- Docker and docker compose (check by command ``` docker --version ``` and ``` docker-compose --version ```).
- Change docker resource path

#### 2.2. Windows
- Step 1: Download or clone this git
- Step 2: Double click run fle ```click-once-windows.bat```

#### 2.3. macOS and linux
- Step 1: Download or clone this git
- Step 2: Run in terminal
```
chmod +x click-once-linux-mac.sh
./click-once-linux-mac.sh
```

#### 2.4. Full step use for other OS
- Step 1: Download or clone this git
- Step 2: Copy ```.env.example``` to ```.env```
- Step 3: Change ```DB_PASSWORD``` in ```.env``` file
- Step 4: Run command
```
docker-compose pull
docker-compose up -d
```

## 3. Custom port web and myPhpAdmin
- Step1: Change WEB_PORT and MPA_PORT in .env file
- Step 2: Run command
```
docker-compose pull
docker-compose up -d
```
## 4. Error permission denied on web:
Open terrminal run command (on Windows remove "sudo" in command):
```
sudo docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/.env
sudo docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/storage
```
