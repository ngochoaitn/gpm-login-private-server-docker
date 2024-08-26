[![en](https://img.shields.io/badge/Language-English-blue.svg)](https://github.com/ngochoaitn/gpm-login-private-server-docker/blob/main/README.md)
[![vi](https://img.shields.io/badge/Ng%C3%B4n%20ng%E1%BB%AF-Ti%E1%BA%BFng%20Vi%E1%BB%87t-red.svg)](https://github.com/ngochoaitn/gpm-login-private-server-docker/blob/main/README.vi.md)

# Đã thử nghiệm trên Ubuntu 22.04, mac M1, Windows 11
- Private server: cổng mặc định 80
    - Tài khoản mặc định: administrator
    - Mật khẩu mặc định: administrator
- phpMyAdmin: cổng mặc định 8081
    - Default username: root
    - Default password: {mặc định trong tệp .env}

## Yêu cần phần cứng
#### Lưu trữ profile trên S3 (khuyến nghị)
- RAM >= 1GB
- CPU >= 1 nhân
- Dung lượng ổ đĩa còn trống >= 5GB
#### Lưu trữ profile trên máy chủ
- RAM >= 2GB
- CPU >= 2 nhân
- Dung lượng ổ đĩa còn trống >= 80GB (phụ thuộc vào số lượng profile)

## Các bước cài đặt cho từng hệ điều hành
#### Ubuntu 22.04
- Bước 1: Chạy lệnh (có thể cần sử dụng sudo)
```
sudo apt install -y git
git clone https://github.com/ngochoaitn/gpm-login-private-server-docker.git
cd gpm-login-private-server-docker
chmod +x click-once-ubuntu-22-04.sh
sudo ./click-once-ubuntu-22-04.sh
```
- Bước 2 (tùy chọn, khuyến nghị): Nếu bạn muốn lưu profile trên S3, đăng nhập vào private server (cổng mặc định 80) và cấu hình mục "Storage setting" của private server.

#### Windows
- Bước 1: Cài đặt [Docker desktop](https://www.docker.com/products/docker-desktop/) (xác minh bằng cách chạy các lệnh `docker --version` và `docker-compose --version`)
- Bước 2: [Tải về](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) hoặc clone git này
- Bước 3: Nhấp đúp vào tệp `click-once-windows.bat`
- Bước 4 (tùy chọn, khuyến nghị): Nếu bạn muốn lưu profile trên S3, đăng nhập vào private server (cổng mặc định 80) và cấu hình mục "Storage setting" của private server.
- Bước 5 (tùy chọn): Bật Docker khởi động cùng máy tính
- Bước 6 (tùy chọn): Thay đổi đường dẫn Resources Docker

#### macOS
- Bước 1: Cài đặt [Docker desktop](https://www.docker.com/products/docker-desktop/) (xác minh bằng cách chạy các lệnh `docker --version` và `docker-compose --version`)
- Bước 2: [Tải về](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) hoặc clone git này
- Bước 3: Chạy lệnh
```
chmod +x click-once-mac.sh
./click-once-mac.sh
```
- Bước 4 (tùy chọn, khuyến nghị): Nếu bạn muốn lưu profile trên S3, đăng nhập vào private server (cổng mặc định 80) và cấu hình mục "Storage setting" của private server.
- Bước 5 (tùy chọn): Bật Docker khởi động cùng máy tính
- Bước 6 (tùy chọn): Thay đổi đường dẫn Resources Docker

#### Các bước đầy đủ sử dụng cho tất cả các hệ điều hành khác (Ubuntu, CentOS, Debian, Linux...)
- Bước 1: Cài đặt Docker và Docker compose (xác minh bằng cách chạy các lệnh `docker --version` và `docker-compose --version`)
- Bước 2: [Tải về](https://github.com/ngochoaitn/gpm-login-private-server-docker/archive/refs/heads/main.zip) hoặc clone git này
- Bước 3: Sao chép `.env.example` thành `.env`
- Bước 4: Thay đổi `DB_PASSWORD` trong tệp `.env`
- Bước 5: Chạy lệnh (có thể cần sử dụng sudo)
```
docker-compose pull
docker-compose up -d

docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/.env
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/storage
docker exec -it gpm-login-private-server-docker-web-1 php artisan key:generate
```
- Bước 6 (tùy chọn, khuyến nghị): Nếu bạn muốn lưu profile trên S3, đăng nhập vào private server (cổng mặc định 80) và cấu hình mục "Storage setting" của private server.
- Bước 7 (tùy chọn): Bật Docker khởi động cùng máy tính
- Bước 8 (tùy chọn): Thay đổi đường dẫn Resources Docker

## Thay đổi cổng web và phpMyAdmin
- Bước 1: Thay đổi giá trị WEB_PORT và PMA_PORT trong tệp .env
- Bước 2: Chạy lệnh
```
docker-compose pull
docker-compose up -d
```

## Khắc phục lỗi "Permission Denied" trên Web
Mở terminal và chạy lệnh sau (có thể cần sử dụng sudo). Thay `gpm-login-private-server-docker` thành tên thư mục hiện tại
```
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/.env
docker exec -it gpm-login-private-server-docker-web-1 chmod 777 /var/www/html/storage
```
