@echo off
setlocal EnableDelayedExpansion

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
    :: Backup the .env file
    copy .env .env.bak
    :: Update the password in the .env file
    powershell -Command "(gc .env) -replace '^DB_PASSWORD=.*', 'DB_PASSWORD=%RANDOM_PASSWORD%' | Out-File -encoding ASCII .env"
    echo DB_PASSWORD updated in .env
) else (
    :: Create a new .env file
    echo DB_CONNECTION=mysql > .env
    echo DB_HOST=mysql >> .env
    echo DB_PORT=3306 >> .env
    echo DB_DATABASE=gpmlogin_db >> .env
    echo DB_USERNAME=sail >> .env
    echo DB_PASSWORD=%RANDOM_PASSWORD% >> .env
    echo File .env has been created with a random password.
)

:: Display the newly generated password
echo Random password: %RANDOM_PASSWORD%

:: Restart Docker Compose with the new password
:: docker-compose down
:: docker-compose up -d

:: Đợi MySQL khởi động
timeout /t 5 /nobreak > nul

:: Update the root and sail passwords in the MySQL container
docker exec -i gpm-login-private-server-docker-mysql-1 mysql -u root -ppassword -e "ALTER USER 'root'@'%%' IDENTIFIED BY '%RANDOM_PASSWORD%'; FLUSH PRIVILEGES;"
docker exec -i gpm-login-private-server-docker-mysql-1 mysql -u root -ppassword -e "ALTER USER 'sail'@'%%' IDENTIFIED BY '%RANDOM_PASSWORD%'; FLUSH PRIVILEGES;"

endlocal
pause
