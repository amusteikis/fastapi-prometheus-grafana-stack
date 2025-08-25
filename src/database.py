import psycopg2
import os
from logger import logger

# Conection parameters
DB_HOST = os.getenv("DB_HOST", "postgres")
DB_NAME = os.getenv("POSTGRES_DB", "mydb")
DB_USER = os.getenv ("POSTGRES_USER", "user")
DB_PASS = os.getenv("POSTGRES_PASSWORD", "password")

# Function to create a database connection
def get_connection():
    return psycopg2.connect(
        host=DB_HOST,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )

# Read items from the database
def get_items():
    logger.info("Fetching items from the database")
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT id, name FROM items")
    rows = cursor.fetchall()
    cursor.close()
    conn.close()
    return [{"id": row[0], "name": row[1]} for row in rows]

# Insert an item into the database
def insert_item(item: dict):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("INSERT INTO items (name) VALUES (%s)", (item["name"],))
    conn.commit()
    cursor.close()
    conn.close()
    return {"message": "Item inserted successfully"}