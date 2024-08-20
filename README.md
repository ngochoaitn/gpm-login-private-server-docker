# gpm-login-private-server-docker
 GPM Login Private Server on Docker

## command
```
docker-compose up -d
```

### Error web:
Open terrminal web and run command:
```
chmod -Rf 777 ./storage
```

### Ubuntu 22.04
```
sudo apt install -y git
git clone https://github.com/ngochoaitn/gpm-login-private-server-docker.git
cd gpm-login-private-server-docker
chmod +x click-once-ubuntu-22-04.sh
sudo ./click-once-ubuntu-22-04.sh
```