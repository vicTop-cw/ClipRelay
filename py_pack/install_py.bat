@echo off
REM ============================================================
REM install_py.bat — 跳板机 Python 环境一键安装
REM 放到目标目录，双击运行即可
REM ============================================================

cd /d "%~dp0"

echo ========================================
echo  Python 数据环境安装
echo ========================================
echo.

REM 检查 Python
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Python 未安装，请先装 Python 3.11
    echo 下载: https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe
    pause
    exit /b 1
)
python --version

echo.
echo [1/3] 安装数据库驱动...
pip install psycopg2-binary sqlalchemy -q

echo [2/3] 安装数据处理...
pip install pandas numpy openpyxl xlrd xlsxwriter -q

echo [3/3] 安装工具库...
pip install pydantic python-dotenv requests urllib3 -q

echo.
echo ========================================
echo  安装完成！
echo ========================================
python -c "import psycopg2, pandas, openpyxl; print('All imports OK')"
pause
