import os
from datetime import datetime
from urllib.parse import quote_plus
from flask import Flask, request, jsonify
from pymongo import MongoClient
from pymongo.errors import ConnectionFailure, PyMongoError

app = Flask(__name__)

# Read connection parameters from environment variables
MONGO_USER = os.environ.get("MONGO_USER")
MONGO_PASSWORD = os.environ.get("MONGO_PASSWORD")
MONGO_HOST = os.environ.get("MONGO_HOST", "localhost")
MONGO_PORT = os.environ.get("MONGO_PORT", "27017")
MONGO_AUTH_DB = os.environ.get("MONGO_AUTH_DB", "admin")
MONGO_DB_NAME = os.environ.get("MONGO_DB_NAME", "flask_db")
MONGODB_URI = os.environ.get("MONGODB_URI")

# Construct connection URI or parameters
if MONGODB_URI:
    client = MongoClient(MONGODB_URI, serverSelectionTimeoutMS=5000)
elif MONGO_USER and MONGO_PASSWORD:
    encoded_user = quote_plus(MONGO_USER)
    encoded_pass = quote_plus(MONGO_PASSWORD)
    uri = f"mongodb://{encoded_user}:{encoded_pass}@{MONGO_HOST}:{MONGO_PORT}/{MONGO_DB_NAME}?authSource={MONGO_AUTH_DB}"
    client = MongoClient(uri, serverSelectionTimeoutMS=5000)
else:
    uri = f"mongodb://{MONGO_HOST}:{MONGO_PORT}/{MONGO_DB_NAME}"
    client = MongoClient(uri, serverSelectionTimeoutMS=5000)

db = client[MONGO_DB_NAME]
collection = db["data"]

@app.route("/", methods=["GET"])
def index():
    return f"Welcome to the Flask app! The current time is: {datetime.now()}"

@app.route("/health", methods=["GET"])
def health():
    try:
        # Ping the admin database to verify MongoDB connectivity
        client.admin.command("ping")
        return jsonify({"status": "healthy", "database": "connected"}), 200
    except (ConnectionFailure, PyMongoError) as err:
        return jsonify({"status": "unhealthy", "database": "disconnected", "error": str(err)}), 503

@app.route("/data", methods=["POST"])
def insert_data():
    content = request.get_json(silent=True)
    if content is None or not isinstance(content, dict):
        return jsonify({"error": "Invalid or missing JSON payload"}), 400
    try:
        collection.insert_one(content)
        return jsonify({"status": "Data inserted"}), 201
    except PyMongoError as err:
        return jsonify({"error": "Database error", "details": str(err)}), 503

@app.route("/data", methods=["GET"])
def get_data():
    try:
        docs = list(collection.find({}, {"_id": 0}))
        return jsonify(docs), 200
    except PyMongoError as err:
        return jsonify({"error": "Database error", "details": str(err)}), 503

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
