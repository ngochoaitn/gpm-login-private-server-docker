@echo off
setlocal EnableDelayedExpansion

:: Check if Docker is installed
docker-compose --version >nul 2>&1

:: If Docker is not installed, exit the script
docker --version >nul 2>&1

:: If Docker is not installed, exit the script
if %ERRORLEVEL% neq 0 (
    echo Docker is not installed. Please install Docker and try again.
    exit /b 1
)


if %ERRORLEVEL% neq 0 (
    echo Docker compose is not installed. Please install Docker and try again.
    exit /b 1
)

if not exist .env (
    copy .env.example .env
)
:: Generate a random password (12 characters, using lowercase letters and numbers)
for /l %%x in (1,1,12) do (
    set /a "rand=!random! %% 36"
    set "randchar=!rand!"
    if !rand! lss 10 (
        set /a "randchar+=48"
    ) else (
        set /a "randchar+=87"
    )
    set "RANDOM_PASSWORD=!RANDOM_PASSWORD!!randchar:~0,1!"
)

:: Check for .env file
if exist .env (
    :: Check if DB_PASSWORD exists and is set to 'password'
    for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"DB_PASSWORD=" .env') do (
        if "%%b"=="password" (
            :: Update the password in the .env file
            powershell -Command "(gc .env) -replace '^DB_PASSWORD=.*', 'DB_PASSWORD=%RANDOM_PASSWORD%' | Out-File -encoding ASCII .env"
            echo DB_PASSWORD updated in .env
            :: Display the newly generated password
            echo Random password: %RANDOM_PASSWORD%
        )
        echo DB_PASSWORD is already set in .env
    )
) else (
    echo .env file not found
)

:: Restart Docker Compose with the new password
docker-compose pull
docker-compose up -d

timeout /t 5 /nobreak > nul

for %%I in (.) do set CURRENT_DIR=%%~nI
echo Current directory: %CURRENT_DIR%
docker exec -it %CURRENT_DIR%-web-1 chmod 777 /var/www/html/.env
docker exec -it %CURRENT_DIR%-web-1 chmod 777 /var/www/html/storage

:: Check if APP_KEY is empty in .env file
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"APP_KEY=" .env') do (
    if "%%b"=="" (
        :: Generate the APP_KEY
        echo create APP_KEY
        docker exec -it %CURRENT_DIR%-web-1 php artisan key:generate
    )
)

echo Done. Private server url: http://machine_ip, eg: http://127.0.0.1

endlocal

pause