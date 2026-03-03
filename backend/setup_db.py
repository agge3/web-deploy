#!/usr/bin/env python3

import subprocess
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from backend.logger import MyLogger

logger = MyLogger.create("setup_db")


def run(cmd, description):
    logger.info(f"Starting: {description}")
    logger.debug(f"Running command: {cmd}")
    result = subprocess.run(cmd, shell=True)
    if result.returncode != 0:
        logger.error(f"Failed: {description} (exit code {result.returncode})")
        sys.exit(1)
    logger.info(f"Completed: {description}")


def check_dependencies():
    try:
        import flask
        import flask_migrate
        import pymysql
        import dotenv
        logger.debug("All dependencies found")
    except ImportError as e:
        logger.error(f"Missing dependency: {e.name}")
        logger.info("Run: pip install -r backend/requirements.txt")
        sys.exit(1)


def check_db_connection():
    from dotenv import load_dotenv
    load_dotenv(os.path.join("backend", ".env"), override=True)
    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        logger.error("DATABASE_URL not set in .env")
        sys.exit(1)
    logger.debug("DATABASE_URL found")

    from sqlalchemy import create_engine
    try:
        engine = create_engine(db_url)
        engine.connect().close()
        logger.info("Database connection successful")
    except Exception as e:
        logger.error(f"Cannot connect to database: {e}")
        logger.info("Make sure MySQL is running and your .env credentials are correct")
        sys.exit(1)


def main():
    logger.info("Beginning database setup")

    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(os.path.join(script_dir, ".."))
    logger.debug(f"Working directory: {os.getcwd()}")

    env_path = os.path.join("backend", ".env")
    if not os.path.exists(env_path):
        logger.error("No .env file found")
        logger.info("Copy .env.example and fill in your credentials:")
        logger.info("  cp backend/.env.example backend/.env")
        sys.exit(1)
    logger.info(".env file found")

    check_dependencies()
    check_db_connection()

    os.environ["FLASK_APP"] = "backend:create_app"

    run(f"{sys.executable} -m flask db upgrade",
        "Applying migrations")

    seed_path = os.path.join("backend", "seed.py")
    if os.path.exists(seed_path):
        run(f"{sys.executable} {seed_path}",
            "Seeding database")
    else:
        logger.warning("seed.py not found, skipping seed")

    logger.info("Setup complete!")


if __name__ == "__main__":
    main()
